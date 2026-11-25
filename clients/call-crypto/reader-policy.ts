/**
 * Transport-free, page-memory reader policy for moq-e2ee-01-wip.
 * A caller must validate/authenticate with the pinned crypto adapter before reporting success.
 * This module does no crypto, network, storage, timers or rendering. Callers dispatch its actions.
 * Every `now` is monotonic page milliseconds: pass `performance.now()`, never `Date.now()` (a wall
 * clock stepped backwards makes every clocked call throw until it catches up).
 */
export type Scope = Readonly<{ profile: string; kid: number; label: string; opaque: string }>;
/** Adapter state names (spec "Adapter states are surfaced by the page"), label scope. */
export type ReaderState =
  | "invite_needed"
  | "ready"
  | "older_stream_only"
  | "unavailable_retryable"
  | "superseded_by_another_instance";
/**
 * Label-scope facts, reported side by side so that no report replaces another. Derived on read
 * from the policy's state as of its last clocked call.
 * - `playback`: an instance is accepted and its stream may render.
 * - `superseded`: the accepted instance is greater than this device's own publishing epoch.
 * - `probing`: a candidate probe is live, or the 12-probe budget is spent (`budget_exhausted` is
 *   `unavailable_retryable` for candidate probing; it never clears playback or the mark).
 * - `olderStreamOnly`: nothing is accepted, no announced candidate is at or above the mark, and at
 *   least one announced candidate is below it.
 */
export type ReaderStatus = Readonly<{
  inviteNeeded: boolean;
  playback: "none" | "ready";
  superseded: boolean;
  probing: "idle" | "probing" | "budget_exhausted";
  olderStreamOnly: boolean;
}>;
export type FrameIdentity = Readonly<{ group: bigint; index: number; authenticated: boolean }>;
export type Mark = Readonly<{ group: bigint; index: number }>;
/** `full`: the candidate table is at its bound. Offer every still-active announcement again later. */
export type AnnounceResult = "ok" | "invalid" | "full";
/** `accepted`: a probe became the accepted instance (first or re-acceptance); `refreshed`: a later
 * manifest frame of the already accepted instance. */
export type Acceptance = "accepted" | "refreshed" | false;
/** Memory and work bounds. Written into the contract; they bound work, not a relay's power to deny. */
export const LIMITS = Object.freeze({
  windowMs: 60_000,
  probesPerWindow: 12,
  probeDeadlineMs: 1500,
  backoffBaseMs: 3000,
  backoffCapMs: 60_000,
  barMs: 60_000,
  resubscribesPerTrack: 6,
  candidates: 256,
  tracksPerInstance: 128,
  startsPerTrack: 128,
});
const EPOCH = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const WINDOW = LIMITS.windowMs;
const validEpoch = (v: unknown): v is string => typeof v === "string" && EPOCH.test(v);

/** Window is in authenticated track group-start units, not public presentation timestamps. */
export class GroupTracker {
  readonly window: bigint;
  readonly mirror: unknown;
  #mark: Mark | undefined;
  #frames = new Map<bigint, number>();
  #evictedThrough = -1n;
  constructor(window: bigint, mirror: unknown = {}) {
    if (typeof window !== "bigint" || window < 0n) throw new RangeError("invalid reorder span");
    this.window = window;
    this.mirror = mirror;
  }
  get mark(): Mark | undefined {
    return this.#mark && { ...this.#mark };
  }
  get remembered(): number {
    return this.#frames.size;
  }
  frame({
    group,
    index,
    authenticated,
  }: FrameIdentity): "deliver" | "duplicate" | "too_old" | "unauthenticated" {
    if (
      typeof group !== "bigint" ||
      group < 0n ||
      group >= 2n ** 64n ||
      !Number.isInteger(index) ||
      index < 0 ||
      index > 0xffffffff
    )
      throw new RangeError("invalid group/frame identity");
    if (!authenticated) return "unauthenticated";
    if (group <= this.#evictedThrough || (this.#mark && group < this.#mark.group - this.window))
      return "too_old";
    if (index <= (this.#frames.get(group) ?? -1)) return "duplicate";
    this.#frames.set(group, index);
    if (
      !this.#mark ||
      group > this.#mark.group ||
      (group === this.#mark.group && index > this.#mark.index)
    )
      this.#mark = { group, index };
    for (const g of this.#frames.keys())
      if (g < this.#mark.group - this.window) this.#frames.delete(g);
    // Dense/malicious starts must not make a time-based window unbounded. Eviction is irreversible:
    // an evicted authenticated group cannot later reopen merely because it still lies in the span.
    while (this.#frames.size > LIMITS.startsPerTrack) {
      let oldest = this.#mark.group;
      for (const g of this.#frames.keys()) if (g < oldest) oldest = g;
      this.#frames.delete(oldest);
      this.#evictedThrough = oldest;
    }
    return "deliver";
  }
}

type Candidate = { barUntil: number; retryAt: number; timeouts: number; available: boolean };
type TrackState = { tracker: GroupTracker; resubs: number[] };
export type TrackAction =
  | { kind: "resubscribe"; epoch: string; track: string; preserveMark: true; preserveMirror: true }
  | { kind: "unavailable_retryable"; track: string; retryAt: number }
  | { kind: "ignored" };
/** Track-scoped refusal: the accepted instance already holds `LIMITS.tracksPerInstance` names. */
export type TrackRefusal = Readonly<{
  kind: "unavailable_retryable";
  track: string;
  reason: "track_limit";
}>;

/** One immutable credential/label scope per object; create a new object for rekey or page reload. */
export class InstancePolicy {
  readonly scope: Scope | undefined;
  #own: string | undefined;
  #mark: string | undefined;
  #accepted: string | undefined;
  #candidates = new Map<string, Candidate>();
  #probe: { epoch: string; started: number } | undefined;
  #attempts: number[] = [];
  // Group/frame marks, mirrors and resubscribe budgets of the MARK epoch, keyed by track name.
  // They live as long as the mark: released only when a greater epoch is accepted, never when the
  // accepted instance ends, so re-accepting the same epoch cannot reopen frames or refill budgets.
  #tracks = new Map<string, TrackState>();
  #now = 0;
  constructor(scope?: Scope, publishingEpoch?: string) {
    if (
      scope &&
      (scope.profile !== "moq-e2ee-01-wip" ||
        !Number.isSafeInteger(scope.kid) ||
        scope.kid < 0 ||
        !/^[-_A-Za-z0-9]{1,64}$/.test(scope.label) ||
        !/^[-_A-Za-z0-9]{22}$/.test(scope.opaque))
    )
      throw new TypeError("invalid profile/credential scope");
    if (publishingEpoch !== undefined && !validEpoch(publishingEpoch))
      throw new TypeError("invalid publishing epoch");
    this.scope = scope && Object.freeze({ ...scope });
    this.#own = publishingEpoch;
  }
  get status(): ReaderStatus {
    const accepted = this.#accepted;
    return Object.freeze({
      inviteNeeded: !this.scope,
      playback: accepted === undefined ? "none" : "ready",
      superseded: accepted !== undefined && this.#own !== undefined && accepted > this.#own,
      probing: this.#probe
        ? "probing"
        : this.#attempts.length >= LIMITS.probesPerWindow
          ? "budget_exhausted"
          : "idle",
      olderStreamOnly: accepted === undefined && this.#olderOnly(),
    });
  }
  /** Spec state names for the facts in `status`: playback state first, then probing exhaustion. */
  get states(): readonly ReaderState[] {
    const s = this.status;
    if (s.inviteNeeded) return Object.freeze(["invite_needed"]);
    const out: ReaderState[] = [
      s.playback === "ready"
        ? s.superseded
          ? "superseded_by_another_instance"
          : "ready"
        : s.olderStreamOnly
          ? "older_stream_only"
          : "unavailable_retryable",
    ];
    if (s.probing === "budget_exhausted" && !out.includes("unavailable_retryable"))
      out.push("unavailable_retryable");
    return Object.freeze(out);
  }
  get mark(): string | undefined {
    return this.#mark;
  }
  get acceptedEpoch(): string | undefined {
    return this.#accepted;
  }
  get publishingEpoch(): string | undefined {
    return this.#own;
  }
  get attemptCount(): number {
    return this.#attempts.length;
  }
  get candidateCount(): number {
    return this.#candidates.size;
  }
  get trackCount(): number {
    return this.#tracks.size;
  }
  #olderOnly(): boolean {
    const mark = this.#mark;
    if (mark === undefined) return false;
    let below = false;
    for (const [e, c] of this.#candidates) {
      if (!c.available) continue;
      if (e >= mark) return false;
      below = true;
    }
    return below;
  }
  #clock(now: number): void {
    if (!Number.isFinite(now) || now < 0 || now < this.#now)
      throw new RangeError("policy clock must be monotonic milliseconds");
    this.#now = now;
    this.#attempts = this.#attempts.filter((t) => t > now - WINDOW);
    this.#purge(now);
  }
  /** Forget retracted records whose bar and backoff have expired. */
  #purge(now: number): void {
    for (const [e, c] of this.#candidates)
      if (
        !c.available &&
        now >= c.barUntil &&
        now >= c.retryAt &&
        e !== this.#probe?.epoch &&
        e !== this.#accepted
      )
        this.#candidates.delete(e);
  }
  /** Timeout rule: back off (3 s doubling, capped at 60 s), never bar. Ends the live probe. */
  #backoff(epoch: string, from: number): void {
    const c = this.#candidates.get(epoch);
    if (c) {
      c.retryAt = from + Math.min(LIMITS.backoffCapMs, LIMITS.backoffBaseMs * 2 ** c.timeouts);
      c.timeouts = Math.min(c.timeouts + 1, 16);
    }
    if (this.#probe?.epoch === epoch) this.#probe = undefined;
  }
  #parse(path: string): string | undefined {
    if (typeof path !== "string") return undefined;
    const p = path.split("/");
    return this.scope &&
      p.length === 3 &&
      p[0] === this.scope.label &&
      p[1] === this.scope.opaque &&
      validEpoch(p[2])
      ? p[2]
      : undefined;
  }
  announce(path: string): AnnounceResult {
    const epoch = this.#parse(path);
    if (epoch === undefined) return "invalid";
    // A duplicate announcement cannot clear a cryptographic refusal or timeout backoff.
    const existing = this.#candidates.get(epoch);
    if (existing) {
      existing.available = true;
      return "ok";
    }
    // At most LIMITS.candidates active announcements/refusal tombstones in one label scope. A relay
    // can deny service by flooding this bound, just as it can withhold the real announcement.
    if (this.#candidates.size >= LIMITS.candidates) this.#purge(this.#now);
    if (this.#candidates.size >= LIMITS.candidates) return "full";
    this.#candidates.set(epoch, { barUntil: 0, retryAt: 0, timeouts: 0, available: true });
    return "ok";
  }
  /** The relay retracted the announcement. Not stream retirement: an existing subscriber can still
   * read. When the reader's own session drops, withdraw every announcement and offer them again on
   * reconnect, so nothing is probed during the outage. */
  withdraw(path: string): void {
    const epoch = this.#parse(path);
    if (epoch === undefined) return;
    const c = this.#candidates.get(epoch);
    if (c) c.available = false;
  }
  /**
   * The ACCEPTED instance's subscription ended (transport close/reset). Not an announcement retract:
   * the candidate stays announced until `withdraw`, and may be probed and re-accepted, keeping its
   * marks, mirrors and budgets. A live probe that ends is `probeEnded`; any other epoch is ignored.
   */
  endInstance(epoch: string): boolean {
    if (!validEpoch(epoch) || epoch !== this.#accepted) return false;
    this.#accepted = undefined;
    return true;
  }
  /** The live probe's manifest subscription ended before authenticating: the timeout rule applies. */
  probeEnded(epoch: string, now: number): boolean {
    this.tick(now);
    if (!validEpoch(epoch) || this.#probe?.epoch !== epoch) return false;
    this.#backoff(epoch, now);
    return true;
  }
  /** Advance deadlines without starting a network operation. */
  tick(now: number): void {
    this.#clock(now);
    const probe = this.#probe;
    if (probe && now - probe.started >= LIMITS.probeDeadlineMs)
      this.#backoff(probe.epoch, probe.started + LIMITS.probeDeadlineMs);
  }
  nextCandidate(now: number): string | undefined {
    this.tick(now);
    if (!this.scope || this.#probe || this.#attempts.length >= LIMITS.probesPerWindow)
      return undefined;
    const eligible = [...this.#candidates]
      .filter(
        ([e, c]) =>
          c.available &&
          e !== this.#accepted &&
          (this.#mark === undefined || e >= this.#mark) &&
          now >= c.barUntil &&
          now >= c.retryAt,
      )
      .map(([e]) => e)
      .sort()
      .reverse();
    return eligible[0];
  }
  /** Call exactly when starting bridge.tracks subscription: this starts the 1500ms deadline. */
  subscribe(epoch: string, now: number): boolean {
    if (this.nextCandidate(now) !== epoch) return false;
    this.#attempts.push(now);
    this.#probe = { epoch, started: now };
    return true;
  }
  /** Only a crypto-authenticated manifest frame may report success; timestamps are not evidence. */
  authenticated(epoch: string, semantic: string, now: number): Acceptance {
    this.tick(now);
    if (!validEpoch(epoch) || semantic !== "bridge.tracks") return false;
    if (epoch === this.#accepted) return "refreshed";
    if (this.#probe?.epoch !== epoch) return false;
    if (this.#mark !== undefined && epoch < this.#mark) return false;
    // Only a mark that moves releases track state: older epochs can never be selected again.
    if (epoch !== this.#mark) this.#tracks.clear();
    this.#mark = epoch;
    this.#accepted = epoch;
    this.#probe = undefined;
    const c = this.#candidates.get(epoch);
    if (c) {
      c.timeouts = 0;
      c.retryAt = 0;
    }
    return "accepted";
  }
  /** Authentication failed on a candidate's manifest: bar it for 60 s, whether or not its probe
   * already timed out. The accepted instance is never a candidate failure. */
  rejectCandidate(epoch: string, now: number): boolean {
    this.tick(now);
    if (!validEpoch(epoch) || epoch === this.#accepted) return false;
    const c = this.#candidates.get(epoch);
    if (!c) return false;
    c.barUntil = now + LIMITS.barMs;
    if (this.#probe?.epoch === epoch) this.#probe = undefined;
    return true;
  }
  resumePublishing(epoch: string): void {
    if (!validEpoch(epoch) || epoch === this.#own)
      throw new TypeError("resume requires a newly minted epoch");
    this.#own = epoch;
  }
  /** A track subscription of the accepted instance failed. Only names passed to `track()` count. */
  trackFailure(epoch: string, track: string, now: number): TrackAction {
    this.tick(now);
    if (this.#accepted === undefined || epoch !== this.#accepted) return { kind: "ignored" };
    const t = this.#tracks.get(track);
    if (!t) return { kind: "ignored" };
    t.resubs = t.resubs.filter((s) => s > now - WINDOW);
    if (t.resubs.length >= LIMITS.resubscribesPerTrack)
      return { kind: "unavailable_retryable", track, retryAt: t.resubs[0] + WINDOW };
    t.resubs.push(now);
    return {
      kind: "resubscribe",
      epoch: this.#accepted,
      track,
      preserveMark: true,
      preserveMirror: true,
    };
  }
  /**
   * The track's mark/mirror holder for the accepted instance; call when subscribing it. `window`
   * and `mirror` are fixed when the tracker is created and kept for the mark's life: a later call
   * returns the same tracker, so compare `tracker.window` to report a `metadata_difference`.
   */
  track(name: string, window: bigint, mirror?: unknown): GroupTracker | TrackRefusal {
    if (this.#accepted === undefined) throw new Error("no accepted instance");
    if (typeof name !== "string") throw new TypeError("invalid track name");
    const existing = this.#tracks.get(name);
    if (existing) return existing.tracker;
    if (this.#tracks.size >= LIMITS.tracksPerInstance)
      return Object.freeze({ kind: "unavailable_retryable", track: name, reason: "track_limit" });
    const tracker = new GroupTracker(window, mirror);
    this.#tracks.set(name, { tracker, resubs: [] });
    return tracker;
  }
}
