/**
 * Transport-free, page-memory reader policy for moq-e2ee-01-wip.
 * A caller must validate/authenticate with the pinned crypto adapter before reporting success.
 * This module does no crypto, network, storage, timers or rendering. Callers dispatch its actions.
 */
export type Scope = Readonly<{ profile: string; kid: number; label: string; opaque: string }>;
export type ReaderState =
  | "invite_needed"
  | "ready"
  | "older_stream_only"
  | "unavailable_retryable"
  | "superseded_by_another_instance";
export type FrameIdentity = Readonly<{ group: bigint; index: number; authenticated: boolean }>;
export type Mark = Readonly<{ group: bigint; index: number }>;
const EPOCH = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const WINDOW = 60_000;
const validEpoch = (v: string) => EPOCH.test(v);

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
    while (this.#frames.size > 128) {
      let oldest = this.#mark.group;
      for (const g of this.#frames.keys()) if (g < oldest) oldest = g;
      this.#frames.delete(oldest);
      this.#evictedThrough = oldest;
    }
    return "deliver";
  }
}

type Candidate = { barUntil: number; retryAt: number; timeouts: number; available: boolean };
export type TrackAction =
  | { kind: "resubscribe"; epoch: string; track: string; preserveMark: true; preserveMirror: true }
  | { kind: "unavailable_retryable" }
  | { kind: "ignored" };

/** One immutable credential/label scope per object; create a new object for rekey or page reload. */
export class InstancePolicy {
  readonly scope: Scope | undefined;
  #own: string | undefined;
  #mark: string | undefined;
  #accepted: string | undefined;
  #state: ReaderState;
  #candidates = new Map<string, Candidate>();
  #probe: { epoch: string; started: number } | undefined;
  #attempts: number[] = [];
  #resubs = new Map<string, number[]>();
  #tracks = new Map<string, GroupTracker>();
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
    this.#state = scope ? "unavailable_retryable" : "invite_needed";
  }
  get state(): ReaderState {
    return this.#state;
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
  #clock(now: number): void {
    if (!Number.isFinite(now) || now < 0 || now < this.#now)
      throw new RangeError("policy clock must be monotonic milliseconds");
    this.#now = now;
    this.#attempts = this.#attempts.filter((t) => t > now - WINDOW);
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
  #parse(path: string): string | undefined {
    const p = path.split("/");
    return this.scope &&
      p.length === 3 &&
      p[0] === this.scope.label &&
      p[1] === this.scope.opaque &&
      validEpoch(p[2])
      ? p[2]
      : undefined;
  }
  announce(path: string): boolean {
    const epoch = this.#parse(path);
    if (epoch === undefined) return false;
    // A duplicate announcement cannot clear a cryptographic refusal or timeout backoff.
    const existing = this.#candidates.get(epoch);
    if (existing) {
      existing.available = true;
      return true;
    }
    // At most 256 active announcements/refusal tombstones in one label scope. A relay can deny
    // service by flooding this bound, just as it can withhold the real announcement.
    if (this.#candidates.size >= 256) return false;
    this.#candidates.set(epoch, { barUntil: 0, retryAt: 0, timeouts: 0, available: true });
    return true;
  }
  withdraw(path: string): void {
    const epoch = this.#parse(path);
    if (epoch === undefined) return;
    const c = this.#candidates.get(epoch);
    if (c) c.available = false;
    // Announcement retraction is not stream retirement: an existing subscriber can still read.
  }
  /** Report the accepted broadcast actually becoming unavailable, not an announcement retract. */
  endInstance(epoch: string): void {
    const c = this.#candidates.get(epoch);
    if (c) c.available = false;
    if (this.#probe?.epoch === epoch) this.#probe = undefined;
    if (this.#accepted === epoch) {
      this.#accepted = undefined;
      this.#state =
        this.#mark && [...this.#candidates].some(([e, c]) => c.available && e < this.#mark!)
          ? "older_stream_only"
          : "unavailable_retryable";
    }
  }
  /** Advance deadlines without starting a network operation. */
  tick(now: number): void {
    this.#clock(now);
    if (this.#probe && now - this.#probe.started >= 1500) {
      const c = this.#candidates.get(this.#probe.epoch);
      if (c) {
        c.retryAt = now + 3000 * 2 ** c.timeouts;
        c.timeouts++;
      }
      this.#probe = undefined;
      if (!this.#accepted) this.#state = "unavailable_retryable";
    }
  }
  nextCandidate(now: number): string | undefined {
    this.tick(now);
    if (!this.scope || this.#probe) return undefined;
    if (this.#attempts.length >= 12) {
      this.#state = "unavailable_retryable";
      return undefined;
    }
    const eligible = [...this.#candidates]
      .filter(
        ([e, c]) =>
          c.available &&
          e !== this.#accepted &&
          (!this.#mark || e >= this.#mark) &&
          now >= c.barUntil &&
          now >= c.retryAt,
      )
      .map(([e]) => e)
      .sort()
      .reverse();
    if (!eligible.length && !this.#accepted)
      this.#state =
        this.#mark && [...this.#candidates].some(([e, c]) => c.available && e < this.#mark!)
          ? "older_stream_only"
          : "unavailable_retryable";
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
  authenticated(epoch: string, semantic: string, now: number): boolean {
    this.tick(now);
    if (semantic !== "bridge.tracks") return false;
    if (epoch === this.#accepted) {
      this.#state = this.#own && epoch > this.#own ? "superseded_by_another_instance" : "ready";
      return true;
    }
    if (this.#probe?.epoch !== epoch) return false;
    if (this.#mark && epoch < this.#mark) return false;
    // Older instances can never be selected again; release their cached mirrors/budgets.
    if (this.#accepted !== epoch) {
      this.#tracks.clear();
      this.#resubs.clear();
    }
    this.#mark = epoch;
    this.#accepted = epoch;
    this.#probe = undefined;
    const c = this.#candidates.get(epoch);
    if (c) {
      c.timeouts = 0;
      c.retryAt = 0;
    }
    this.#state = this.#own && epoch > this.#own ? "superseded_by_another_instance" : "ready";
    return true;
  }
  rejectCandidate(epoch: string, now: number): boolean {
    this.#clock(now);
    if (epoch === this.#accepted || this.#probe?.epoch !== epoch) return false;
    const c = this.#candidates.get(epoch);
    if (c) c.barUntil = now + WINDOW;
    this.#probe = undefined;
    if (!this.#accepted) this.#state = "unavailable_retryable";
    return true;
  }
  resumePublishing(epoch: string): void {
    if (!validEpoch(epoch) || epoch === this.#own)
      throw new TypeError("resume requires a newly minted epoch");
    this.#own = epoch;
    this.#state = this.#accepted ? "ready" : "unavailable_retryable";
  }
  trackFailure(epoch: string, track: string, now: number): TrackAction {
    this.#clock(now);
    if (!this.#accepted || epoch !== this.#accepted) return { kind: "ignored" };
    const key = JSON.stringify([this.#accepted, track]);
    const used = (this.#resubs.get(key) ?? []).filter((t) => t > now - WINDOW);
    this.#resubs.set(key, used);
    if (used.length >= 6) return { kind: "unavailable_retryable" };
    used.push(now);
    return {
      kind: "resubscribe",
      epoch: this.#accepted,
      track,
      preserveMark: true,
      preserveMirror: true,
    };
  }
  track(name: string, window: bigint): GroupTracker {
    if (!this.#accepted) throw new Error("no accepted instance");
    const key = JSON.stringify([this.#accepted, name]);
    const existing = this.#tracks.get(key);
    if (existing) {
      if (existing.window !== window) throw new TypeError("cannot change a live mark window");
      return existing;
    }
    const created = new GroupTracker(window);
    this.#tracks.set(key, created);
    return created;
  }
}
