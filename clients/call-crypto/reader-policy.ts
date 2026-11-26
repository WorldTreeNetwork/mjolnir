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
 * - `probing`: a candidate probe is live.
 * - `budgetExhausted`: all 12 probes of the rolling minute are spent, including the live one
 *   (`unavailable_retryable` for candidate probing; it never clears playback or the mark).
 * - `olderStreamOnly`: nothing is accepted, no announced candidate is at or above the mark, at
 *   least one announced candidate is below it, and the candidate table is complete.
 * - `candidatesIncomplete`: an announcement was refused as `full`, or an active record was evicted,
 *   so the policy may not know every announced epoch. Only `reconcile()` with the complete active
 *   set clears it.
 */
export type ReaderStatus = Readonly<{
  inviteNeeded: boolean;
  playback: "none" | "ready";
  superseded: boolean;
  probing: "idle" | "probing";
  budgetExhausted: boolean;
  olderStreamOnly: boolean;
  candidatesIncomplete: boolean;
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
  /** A failure report from a probe is honored until this long after that probe started. */
  lateReportMs: 60_000,
  /** An accepted subscription that ends sooner than this after acceptance is a rapid close. */
  rapidCloseMs: 10_000,
});
const EPOCH = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const WINDOW = LIMITS.windowMs;
const validEpoch = (v: unknown): v is string => typeof v === "string" && EPOCH.test(v);

/** Window is in authenticated track group-start units, not public presentation timestamps.
 * Standalone replay filter. Inside an `InstancePolicy` it is reached only through a `TrackHandle`. */
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
    // Only a primitive boolean is an authentication outcome: "false", 1 or {} must not deliver.
    if (typeof authenticated !== "boolean") throw new TypeError("invalid authentication outcome");
    if (authenticated !== true) return "unauthenticated";
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

type Candidate = { retryAt: number; timeouts: number; available: boolean };
type TrackState = {
  tracker: GroupTracker;
  resubs: number[];
  handle: TrackHandle | undefined;
  // After an exhausted terminal failure: no new handle before this time (`retryTrack`).
  blockedUntil: number;
  // The single outstanding permission left by the last terminal failure: `resubscribe` lets one
  // replacement start through `track()`, `retry` one through `retryTrack()` at `blockedUntil`.
  grant: "none" | "resubscribe" | "retry";
};
type Sub = {
  epoch: string;
  seq: number;
  started: number;
  acceptedAt: number | undefined;
  reported: boolean;
};
type Bar = { until: number; seq: number };
/**
 * Opaque identity of ONE manifest (`bridge.tracks`) subscription attempt, returned by `subscribe`.
 * The caller keeps the returned reference with that subscription and passes it back on every
 * callback of that subscription: `authenticated`, `probeEnded`, `rejectCandidate`, `endInstance`
 * and `track`. Only the reference this policy issued carries authority; a copy, a clone or another
 * policy's handle is refused. A handle that is not the live probe or the accepted session is
 * refused, so a late event from an earlier attempt of the same epoch cannot act on its replacement.
 */
export type Subscription = Readonly<{ epoch: string }>;
export type TrackAction =
  | { kind: "resubscribe"; epoch: string; track: string; preserveMark: true; preserveMirror: true }
  | { kind: "unavailable_retryable"; track: string; retryAt: number }
  | { kind: "ignored" };
/** Track-scoped refusal: `track_limit` at `LIMITS.tracksPerInstance` names; `stale` when the
 * session handle is not the accepted session (a callback of a retired subscription), or when there
 * is no outstanding retry; `retry_wait` while an exhausted track waits for `retryAt`; `live` when
 * the name already has a current subscription (no second start, no uncharged replacement). */
export type TrackRefusal = Readonly<
  | { kind: "unavailable_retryable"; track: string; reason: "track_limit" }
  | { kind: "unavailable_retryable"; track: string; reason: "retry_wait"; retryAt: number }
  | { kind: "stale"; track: string }
  | { kind: "live"; track: string }
>;
export type FrameResult = "deliver" | "duplicate" | "too_old" | "unauthenticated" | "stale";
/** Result of `reconcile`: `complete` only when every active announcement fit in the table. */
export type ReconcileResult = "complete" | "incomplete";
/** Test and diagnostics view of the bounded internals. Not an API for page logic. */
export type PolicyInternals = Readonly<{
  now: number;
  incomplete: boolean;
  probe: string | undefined;
  candidates: readonly Readonly<{ epoch: string; available: boolean; retryAt: number }>[];
  bars: readonly Readonly<{ epoch: string; until: number }>[];
  paceRetryAt: number;
  tracks: readonly Readonly<{
    name: string;
    resubs: number;
    remembered: number;
    mark: Mark | undefined;
    blockedUntil: number;
  }>[];
}>;

/**
 * One track subscription of the accepted session, returned by `InstancePolicy.track`. The mark,
 * mirror and resubscribe budget belong to the track name for the mark's life; the handle belongs to
 * one subscription. Once the session ends, the name is subscribed again, or the subscription has
 * reported its terminal failure, this handle is stale: `frame` returns `stale` without touching the
 * mark. Apply a frame to `mirror` only in the same synchronous step as a `deliver` result, or check
 * `current` again at the mirror if work yielded in between.
 */
export class TrackHandle {
  readonly name: string;
  readonly #state: TrackState;
  readonly #live: (h: TrackHandle) => boolean;
  constructor(name: string, state: TrackState, live: (h: TrackHandle) => boolean) {
    this.name = name;
    this.#state = state;
    this.#live = live;
  }
  /** False once the session retired, the track was subscribed again, or it failed terminally. */
  get current(): boolean {
    return this.#live(this);
  }
  get window(): bigint {
    return this.#state.tracker.window;
  }
  get mirror(): unknown {
    return this.#state.tracker.mirror;
  }
  get mark(): Mark | undefined {
    return this.#state.tracker.mark;
  }
  get remembered(): number {
    return this.#state.tracker.remembered;
  }
  frame(identity: FrameIdentity): FrameResult {
    if (!this.#live(this)) return "stale";
    return this.#state.tracker.frame(identity);
  }
}

const finite = (n: unknown): n is number => typeof n === "number" && Number.isFinite(n);
const LABEL = /^[-_A-Za-z0-9]{1,64}$/;
const OPAQUE = /^[-_A-Za-z0-9]{22}$/;

/** One immutable credential/label scope per object; create a new object for rekey or page reload. */
export class InstancePolicy {
  readonly scope: Scope | undefined;
  #own: string | undefined;
  #mark: string | undefined;
  #candidates = new Map<string, Candidate>();
  // Authentication bars by epoch, kept apart from the candidate table so that purging a withdrawn
  // record never shortens a bar. Only issued probes create bars, one report per probe, so this
  // holds at most the probes of the last two minutes.
  #bars = new Map<string, Bar>();
  #subs = new WeakMap<Subscription, Sub>();
  #seq = 0;
  #probe: Subscription | undefined;
  #session: Subscription | undefined;
  // Sequence of the newest accepted attempt of the mark epoch. A failure report from an earlier
  // attempt of that epoch is stale: an authenticated acceptance is stronger evidence.
  #markAcceptSeq = -1;
  #attempts: number[] = [];
  // Group/frame marks, mirrors and resubscribe budgets of the MARK epoch, keyed by track name.
  // They live as long as the mark: released only when a greater epoch is accepted, never when the
  // accepted session ends, so re-accepting the same epoch cannot reopen frames or refill budgets.
  #tracks = new Map<string, TrackState>();
  #sessionOf = new WeakMap<TrackHandle, Subscription>();
  // Pacing of re-acceptance of the mark epoch after rapid closes. Reset when the mark moves.
  #pace = { rapid: 0, retryAt: 0 };
  #incomplete = false;
  #now = 0;
  constructor(scope?: Scope, publishingEpoch?: string) {
    // Absent scope is `undefined` only; a present one has exactly the declared primitive types.
    if (
      scope !== undefined &&
      (typeof scope !== "object" ||
        scope === null ||
        scope.profile !== "moq-e2ee-01-wip" ||
        typeof scope.kid !== "number" ||
        !Number.isSafeInteger(scope.kid) ||
        scope.kid < 0 ||
        typeof scope.label !== "string" ||
        !LABEL.test(scope.label) ||
        typeof scope.opaque !== "string" ||
        !OPAQUE.test(scope.opaque))
    )
      throw new TypeError("invalid profile/credential scope");
    if (publishingEpoch !== undefined && !validEpoch(publishingEpoch))
      throw new TypeError("invalid publishing epoch");
    this.scope = scope && Object.freeze({ ...scope });
    this.#own = publishingEpoch;
  }
  get #accepted(): string | undefined {
    return this.#session && this.#subs.get(this.#session)!.epoch;
  }
  get status(): ReaderStatus {
    const accepted = this.#accepted;
    return Object.freeze({
      inviteNeeded: !this.scope,
      playback: accepted === undefined ? "none" : "ready",
      superseded: accepted !== undefined && this.#own !== undefined && accepted > this.#own,
      probing: this.#probe ? "probing" : "idle",
      budgetExhausted: this.#attempts.length >= LIMITS.probesPerWindow,
      olderStreamOnly: accepted === undefined && !this.#incomplete && this.#olderOnly(),
      candidatesIncomplete: this.#incomplete,
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
    if (s.budgetExhausted && !out.includes("unavailable_retryable"))
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
  /** Bounded internals for tests and diagnostics. */
  inspect(): PolicyInternals {
    return Object.freeze({
      now: this.#now,
      incomplete: this.#incomplete,
      probe: this.#probe && this.#subs.get(this.#probe)!.epoch,
      // A fresh copy each call, so freezing the outer arrays is enough; this runs per test step.
      candidates: Object.freeze(
        Array.from(this.#candidates, ([epoch, c]) => ({ epoch, available: c.available, retryAt: c.retryAt })),
      ),
      bars: Object.freeze(Array.from(this.#bars, ([epoch, b]) => ({ epoch, until: b.until }))),
      paceRetryAt: this.#pace.retryAt,
      tracks: [...this.#tracks].map(([name, t]) =>
        Object.freeze({
          name,
          resubs: t.resubs.length,
          remembered: t.tracker.remembered,
          mark: t.tracker.mark,
          blockedUntil: t.blockedUntil,
        }),
      ),
    });
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
  /** A subscription reference this policy issued (not a copy, clone or foreign handle). */
  #issued(sub: unknown): sub is Subscription {
    return typeof sub === "object" && sub !== null && this.#subs.has(sub as Subscription);
  }
  #clock(now: number): void {
    if (!finite(now) || now < 0 || now < this.#now)
      throw new RangeError("policy clock must be monotonic milliseconds");
    this.#now = now;
    this.#attempts = this.#attempts.filter((t) => t > now - WINDOW);
    for (const [e, b] of this.#bars) if (now >= b.until) this.#bars.delete(e);
  }
  /** Forget retracted records whose backoff has expired. Bars live in `#bars` and are not lost. */
  #purge(now: number): void {
    const probe = this.#probe && this.#subs.get(this.#probe)!.epoch;
    for (const [e, c] of this.#candidates)
      if (!c.available && now >= c.retryAt && e !== probe && e !== this.#accepted)
        this.#candidates.delete(e);
  }
  /** Timeout rule: back off (3 s doubling, capped at 60 s), never bar. Ends the live probe. */
  #backoff(epoch: string, from: number): void {
    const c = this.#candidates.get(epoch);
    if (c) {
      c.retryAt = from + Math.min(LIMITS.backoffCapMs, LIMITS.backoffBaseMs * 2 ** c.timeouts);
      c.timeouts = Math.min(c.timeouts + 1, 16);
    }
    this.#probe = undefined;
  }
  #parse(path: unknown): string | undefined {
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
  /** Make room for an epoch at or above the mark by forgetting a below-mark record, withdrawn ones
   * first. Below-mark records are never probed; they only feed the older-only report, so forgetting
   * an active one makes the view incomplete. */
  #evictBelowMark(): boolean {
    const mark = this.#mark;
    if (mark === undefined) return false;
    let active: string | undefined;
    for (const [e, c] of this.#candidates) {
      if (e >= mark || e === this.#accepted) continue;
      if (!c.available) {
        this.#candidates.delete(e);
        return true;
      }
      active ??= e;
    }
    if (active === undefined) return false;
    this.#candidates.delete(active);
    this.#incomplete = true;
    return true;
  }
  #admit(epoch: string): AnnounceResult {
    // A duplicate announcement cannot clear a cryptographic refusal or timeout backoff.
    const existing = this.#candidates.get(epoch);
    if (existing) {
      existing.available = true;
      return "ok";
    }
    // At most LIMITS.candidates active announcements/retry tombstones in one label scope. A relay
    // can deny service by flooding this bound, just as it can withhold the real announcement.
    if (this.#candidates.size >= LIMITS.candidates) this.#purge(this.#now);
    if (
      this.#candidates.size >= LIMITS.candidates &&
      !(this.#mark !== undefined && epoch >= this.#mark && this.#evictBelowMark())
    ) {
      this.#incomplete = true;
      return "full";
    }
    this.#candidates.set(epoch, { retryAt: 0, timeouts: 0, available: true });
    return "ok";
  }
  announce(path: string): AnnounceResult {
    const epoch = this.#parse(path);
    if (epoch === undefined) return "invalid";
    return this.#admit(epoch);
  }
  /** The relay retracted the announcement. Not stream retirement: an existing subscriber can still
   * read. When the reader's own session drops, withdraw every announcement and `reconcile` the
   * active set on reconnect, so nothing is probed during the outage. */
  withdraw(path: string): void {
    const epoch = this.#parse(path);
    if (epoch === undefined) return;
    const c = this.#candidates.get(epoch);
    if (c) c.available = false;
  }
  /**
   * The adapter's complete, authoritative set of this label's active announcement paths (an empty
   * set is a valid answer). Records not in it become withdrawn; the greatest `LIMITS.candidates`
   * epochs in it are offered. The view becomes complete only if every active epoch fits. Every
   * element must be a well-formed `<label>/<opaque>/<epoch>` string: a well-formed path of another
   * label or opaque is ignored, anything else (a non-string, a malformed path, a bad epoch for this
   * scope, a non-iterable, a string as the set, or an iterator that throws) refuses the whole call
   * before any change. Scratch memory is bounded by `LIMITS.candidates` whatever the input length.
   */
  reconcile(active: Iterable<string>): ReconcileResult {
    if (
      active === null ||
      typeof active === "string" ||
      typeof (active as any)?.[Symbol.iterator] !== "function"
    )
      throw new TypeError("reconcile needs the iterable active set");
    // One pass, validating every element, keeping only the greatest K distinct epochs (descending).
    // An epoch below a full top-K, or one evicted from it, is distinct from all K kept, so the set
    // has more than K epochs: overflow is exact with bounded memory.
    const K = LIMITS.candidates;
    const top: string[] = [];
    let overflow = false;
    for (const path of active) {
      if (typeof path !== "string") throw new TypeError("reconcile: path is not a string");
      const seg = path.split("/");
      if (seg.length !== 3 || !LABEL.test(seg[0]) || !OPAQUE.test(seg[1]))
        throw new TypeError("reconcile: malformed path");
      if (!this.scope || seg[0] !== this.scope.label || seg[1] !== this.scope.opaque) continue;
      const e = seg[2];
      if (!validEpoch(e)) throw new TypeError("reconcile: malformed epoch");
      let lo = 0;
      let hi = top.length;
      while (lo < hi) {
        const mid = (lo + hi) >> 1;
        if (top[mid] > e) lo = mid + 1;
        else hi = mid;
      }
      if (top[lo] === e) continue;
      if (top.length < K) top.splice(lo, 0, e);
      else if (lo < K) {
        top.splice(lo, 0, e);
        top.pop();
        overflow = true;
      } else overflow = true;
    }
    const kept = new Set(top);
    for (const [e, c] of this.#candidates) if (!kept.has(e)) c.available = false;
    let fits = !overflow;
    for (const e of top) if (this.#admit(e) === "full") fits = false;
    this.#incomplete = !fits;
    return fits ? "complete" : "incomplete";
  }
  /**
   * The ACCEPTED session's subscription ended (transport close/reset). `sub` must be the accepted
   * session's handle; a close of any earlier attempt is ignored. Not an announcement retract: the
   * epoch stays announced and may be re-accepted, keeping its marks, mirrors and budgets. A close
   * within `LIMITS.rapidCloseMs` of acceptance is rapid: the first allows an immediate reconnect,
   * each further consecutive rapid close delays re-probing this epoch 3 s doubling to 60 s. A
   * session that lasted `rapidCloseMs` resets the count to zero. Other epochs and the budget are
   * unaffected by this delay.
   */
  endInstance(sub: Subscription, now: number): boolean {
    // Authority first: a refused call must not even advance the clock.
    if (!this.#issued(sub) || sub !== this.#session || !finite(now)) return false;
    this.tick(now);
    const lived = now - this.#subs.get(sub)!.acceptedAt!;
    this.#pace.rapid = lived < LIMITS.rapidCloseMs ? this.#pace.rapid + 1 : 0;
    const r = this.#pace.rapid;
    this.#pace.retryAt =
      now + (r <= 1 ? 0 : Math.min(LIMITS.backoffCapMs, LIMITS.backoffBaseMs * 2 ** (r - 2)));
    this.#session = undefined;
    return true;
  }
  /** The live probe's manifest subscription ended before authenticating: the timeout rule applies.
   * Only the live probe's handle is heard; anything else is refused before the clock moves. If the
   * probe's own deadline has passed at `now`, the deadline already applied its backoff: the clock
   * advances and the call returns `false`. */
  probeEnded(sub: Subscription, now: number): boolean {
    if (!this.#issued(sub) || sub !== this.#probe || !finite(now)) return false;
    this.tick(now);
    if (sub !== this.#probe) return false;
    this.#backoff(this.#subs.get(sub)!.epoch, now);
    return true;
  }
  /** Advance deadlines without starting a network operation. */
  tick(now: number): void {
    this.#clock(now);
    const probe = this.#probe && this.#subs.get(this.#probe)!;
    if (probe && now - probe.started >= LIMITS.probeDeadlineMs)
      this.#backoff(probe.epoch, probe.started + LIMITS.probeDeadlineMs);
    // After the deadline, so a probe that expires in this tick is purged in it (idempotent tick).
    this.#purge(now);
  }
  nextCandidate(now: number): string | undefined {
    this.tick(now);
    return this.#eligibleAt(now);
  }
  /** The candidate `nextCandidate(now)` would return, computed without changing anything: the
   * effects of a tick at `now` (deadline, attempt window, bar expiry) are applied in the comparison
   * only. `now` must already be a valid clock value. */
  #eligibleAt(now: number): string | undefined {
    if (!this.scope) return undefined;
    let expired: string | undefined;
    let expiredRetry = 0;
    const probe = this.#probe && this.#subs.get(this.#probe)!;
    if (probe) {
      if (now - probe.started < LIMITS.probeDeadlineMs) return undefined;
      expired = probe.epoch;
      const c = this.#candidates.get(expired);
      if (c)
        expiredRetry =
          probe.started +
          LIMITS.probeDeadlineMs +
          Math.min(LIMITS.backoffCapMs, LIMITS.backoffBaseMs * 2 ** c.timeouts);
    }
    let attempts = 0;
    for (const t of this.#attempts) if (t > now - WINDOW) attempts++;
    if (attempts >= LIMITS.probesPerWindow) return undefined;
    let best: string | undefined;
    for (const [e, c] of this.#candidates)
      if (
        c.available &&
        e !== this.#accepted &&
        (this.#mark === undefined || e >= this.#mark) &&
        (e !== this.#mark || now >= this.#pace.retryAt) &&
        now >= (this.#bars.get(e)?.until ?? 0) &&
        now >= (e === expired ? expiredRetry : c.retryAt) &&
        (best === undefined || e > best)
      )
        best = e;
    return best;
  }
  /** Call exactly when starting a bridge.tracks subscription: starts the 1500 ms deadline and
   * returns the handle every callback of that subscription must carry, or `false` when `epoch` is
   * not the eligible candidate now (no handle is issued and no probe slot is spent). */
  subscribe(epoch: string, now: number): Subscription | false {
    if (!validEpoch(epoch) || !finite(now) || now < this.#now) return false;
    // Decide eligibility without a tick, so a refused start changes nothing (not even the clock).
    if (this.#eligibleAt(now) !== epoch) return false;
    this.tick(now);
    this.#attempts.push(now);
    const sub: Subscription = Object.freeze({ epoch });
    this.#subs.set(sub, {
      epoch,
      seq: this.#seq++,
      started: now,
      acceptedAt: undefined,
      reported: false,
    });
    this.#probe = sub;
    return sub;
  }
  /** Only a crypto-authenticated manifest frame may report success; timestamps are not evidence. */
  authenticated(sub: Subscription, semantic: string, now: number): Acceptance {
    if (semantic !== "bridge.tracks" || !this.#issued(sub) || !finite(now)) return false;
    // Authority before the clock: only the accepted session or the live probe is heard.
    if (sub !== this.#session && sub !== this.#probe) return false;
    this.tick(now);
    if (sub === this.#session) return "refreshed";
    // The probe's own deadline passed at `now`: the timeout applied, the late frame cannot accept.
    if (sub !== this.#probe) return false;
    const st = this.#subs.get(sub)!;
    const epoch = st.epoch;
    if (this.#mark !== undefined && epoch < this.#mark) return false;
    // Only a mark that moves releases track state and pacing: older epochs are never selected again.
    if (epoch !== this.#mark) {
      this.#tracks.clear();
      this.#pace = { rapid: 0, retryAt: 0 };
      this.#markAcceptSeq = -1;
    }
    this.#mark = epoch;
    st.acceptedAt = now;
    this.#markAcceptSeq = Math.max(this.#markAcceptSeq, st.seq);
    // A bar from an earlier attempt of this epoch is superseded by this authenticated open.
    const bar = this.#bars.get(epoch);
    if (bar && bar.seq < st.seq) this.#bars.delete(epoch);
    this.#session = sub;
    this.#probe = undefined;
    const c = this.#candidates.get(epoch);
    if (c) {
      c.timeouts = 0;
      c.retryAt = 0;
    }
    return "accepted";
  }
  /**
   * Authentication failed on a probe's manifest. `sub` must be a probe this policy issued that was
   * never accepted, reported within `LIMITS.lateReportMs` of its start, whether or not it is still
   * live. One report per probe: a repeated report is refused and never extends the bar. A report
   * from an attempt older than a later authenticated acceptance of the same epoch is refused. The
   * bar (60 s from the report) does not depend on tick or purge order, and a report from an earlier
   * attempt does not end a live replacement probe.
   */
  rejectCandidate(sub: Subscription, now: number): boolean {
    if (!this.#issued(sub) || !finite(now) || now < this.#now) return false;
    const st = this.#subs.get(sub)!;
    if (st.acceptedAt !== undefined || st.reported || now >= st.started + LIMITS.lateReportMs)
      return false;
    // Fences, all checked before the clock moves: a report from an attempt older than an accepted
    // attempt of the mark epoch, or about any epoch below the mark (never selectable again; this
    // keeps the fence after a greater epoch is accepted without remembering acceptance history).
    if (st.epoch === this.#mark && st.seq < this.#markAcceptSeq) return false;
    if (this.#mark !== undefined && st.epoch < this.#mark) return false;
    this.tick(now);
    st.reported = true;
    const prior = this.#bars.get(st.epoch);
    const until = now + LIMITS.barMs;
    if (!prior || prior.until < until) this.#bars.set(st.epoch, { until, seq: st.seq });
    if (this.#probe === sub) this.#probe = undefined;
    return true;
  }
  resumePublishing(epoch: string): void {
    if (!validEpoch(epoch) || epoch === this.#own)
      throw new TypeError("resume requires a newly minted epoch");
    this.#own = epoch;
  }
  #live = (h: TrackHandle): boolean =>
    this.#session !== undefined &&
    this.#sessionOf.get(h) === this.#session &&
    this.#tracks.get(h.name)?.handle === h;
  /**
   * A current track subscription failed terminally. The handle retires on the first report (both
   * branches), keeping the name's mark, mirror and budget. `resubscribe`: call `track()` for the
   * replacement. `unavailable_retryable`: call `retryTrack()` at or after `retryAt`.
   */
  trackFailure(handle: TrackHandle, now: number): TrackAction {
    if (
      !(handle instanceof TrackHandle) ||
      !this.#sessionOf.has(handle) ||
      !this.#live(handle) ||
      !finite(now) ||
      now < this.#now
    )
      return { kind: "ignored" };
    this.tick(now);
    const t = this.#tracks.get(handle.name)!;
    t.handle = undefined;
    t.resubs = t.resubs.filter((s) => s > now - WINDOW);
    if (t.resubs.length >= LIMITS.resubscribesPerTrack) {
      t.blockedUntil = t.resubs[0] + WINDOW;
      t.grant = "retry";
      return { kind: "unavailable_retryable", track: handle.name, retryAt: t.blockedUntil };
    }
    // The replacement is charged when it starts, once (`track()`), not here.
    t.grant = "resubscribe";
    return {
      kind: "resubscribe",
      epoch: this.#accepted!,
      track: handle.name,
      preserveMark: true,
      preserveMirror: true,
    };
  }
  /** The clocked retry after `unavailable_retryable`: consumes the one outstanding retry and starts
   * a new handle for that name, keeping its window, mirror and marks. Refused before the clock moves
   * unless `sub` is the accepted session, the name is known, has no current subscription and has an
   * outstanding retry; `retry_wait` before `retryAt`. The start is charged to the rolling budget. */
  retryTrack(sub: Subscription, name: string, now: number): TrackHandle | TrackRefusal {
    if (typeof name !== "string") throw new TypeError("invalid track name");
    if (!this.#issued(sub) || sub !== this.#session || !finite(now) || now < this.#now)
      return Object.freeze({ kind: "stale", track: name });
    const t = this.#tracks.get(name);
    if (!t) return Object.freeze({ kind: "stale", track: name });
    if (t.handle && this.#live(t.handle)) return Object.freeze({ kind: "live", track: name });
    if (t.grant !== "retry") return Object.freeze({ kind: "stale", track: name });
    if (now < t.blockedUntil)
      return Object.freeze({
        kind: "unavailable_retryable",
        track: name,
        reason: "retry_wait",
        retryAt: t.blockedUntil,
      });
    this.tick(now);
    return this.#start(sub, name, t, true);
  }
  /** Issue the handle for one subscription start; `charged` records it in the rolling budget. */
  #start(sub: Subscription, name: string, t: TrackState, charged: boolean): TrackHandle {
    if (charged) {
      t.resubs = t.resubs.filter((s) => s > this.#now - WINDOW);
      t.resubs.push(this.#now);
    }
    t.grant = "none";
    const handle = new TrackHandle(name, t, this.#live);
    this.#sessionOf.set(handle, sub);
    t.handle = handle;
    return handle;
  }
  /**
   * Start a track subscription of the accepted session `sub`: the first subscription of a name, or
   * the replacement a `resubscribe` result allowed (charged once, at this start, at the policy's
   * current time). Returns the handle for that one subscription or a refusal: `stale` if `sub` is
   * not the accepted session; `live` if the name already has a current subscription; `retry_wait`
   * after exhaustion (use `retryTrack`); `track_limit`. A new session starts a name without a
   * pending grant for free; a pending `resubscribe` is consumed and charged in any session.
   * `window` and `mirror` are fixed when the name is first seen and kept for the mark's life;
   * compare `handle.window` to report a `metadata_difference`. Pass `now`, the time the
   * subscription actually starts, so a charged replacement is stamped then; without it the start
   * is stamped at the last clocked call. The clock moves only when a handle is issued.
   */
  track(
    sub: Subscription,
    name: string,
    window: bigint,
    mirror?: unknown,
    now?: number,
  ): TrackHandle | TrackRefusal {
    if (typeof name !== "string") throw new TypeError("invalid track name");
    if (typeof window !== "bigint" || window < 0n) throw new RangeError("invalid reorder span");
    if (now !== undefined && (!finite(now) || now < this.#now))
      throw new RangeError("policy clock must be monotonic milliseconds");
    if (!this.#issued(sub) || sub !== this.#session)
      return Object.freeze({ kind: "stale", track: name });
    const state = this.#tracks.get(name);
    if (!state) {
      if (this.#tracks.size >= LIMITS.tracksPerInstance)
        return Object.freeze({ kind: "unavailable_retryable", track: name, reason: "track_limit" });
      const t: TrackState = {
        tracker: new GroupTracker(window, mirror),
        resubs: [],
        handle: undefined,
        blockedUntil: 0,
        grant: "none",
      };
      this.#tracks.set(name, t);
      if (now !== undefined) this.tick(now);
      return this.#start(sub, name, t, false);
    }
    if (state.handle && this.#live(state.handle)) return Object.freeze({ kind: "live", track: name });
    if (state.grant === "retry")
      return Object.freeze({
        kind: "unavailable_retryable",
        track: name,
        reason: "retry_wait",
        retryAt: state.blockedUntil,
      });
    if (now !== undefined) this.tick(now);
    return this.#start(sub, name, state, state.grant === "resubscribe");
  }
}
