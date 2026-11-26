// Seeded randomized check of the C1 reader policy. Long random sequences of every public call,
// including stale, cloned, foreign and malformed handles, duplicate and late reports, equal-time
// orderings and table overflow. After every step it asserts the invariants the reviews established.
// A failure prints `seed`, `step` and the operation; replay with RANDOM_SEED=<seed>.
import { test } from "node:test";
import assert from "node:assert/strict";
import { InstancePolicy, TrackHandle, LIMITS } from "./reader-policy.ts";
import type { Subscription } from "./reader-policy.ts";

const SEEDS = Number(process.env.RANDOM_SEEDS ?? 200);
const STEPS = Number(process.env.RANDOM_STEPS ?? 2000);
const ONLY = process.env.RANDOM_SEED;

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const epoch = (n: number) => `${n.toString(16).padStart(8, "0")}-0000-7000-8000-000000000000`;
const scope = { profile: "moq-e2ee-01-wip", kid: 1, label: "alice", opaque: "A".repeat(22) };
const path = (e: string) => `alice/${scope.opaque}/${e}`;
const bigintSafe = (_k: string, v: unknown) => (typeof v === "bigint" ? `${v}n` : v);
// Field-level difference of two snapshots, for a readable failure.
function diff(a: any, b: any, at = ""): string[] {
  if (JSON.stringify(a) === JSON.stringify(b)) return [];
  if (a && b && typeof a === "object" && typeof b === "object" && !Array.isArray(a))
    return [...new Set([...Object.keys(a), ...Object.keys(b)])].flatMap((k) => diff(a[k], b[k], `${at}.${k}`));
  return [`${at}: ${JSON.stringify(a)} -> ${JSON.stringify(b)}`];
}

function run(seed: number): void {
  const r = mulberry32(seed);
  const int = (n: number) => Math.floor(r() * n);
  const pick = <T,>(xs: readonly T[]): T => xs[int(xs.length)];
  const chance = (q: number) => r() < q;

  let fresh = 100;
  const p = new InstancePolicy(scope, chance(0.3) ? epoch(5) : undefined);
  const other = new InstancePolicy(scope);
  other.announce(path(epoch(3)));
  const foreign = other.subscribe(epoch(3), 0) as Subscription;
  other.authenticated(foreign, "bridge.tracks", 1);

  const subs: Subscription[] = [];
  const tracks: TrackHandle[] = [];
  const reported = new Set<Subscription>();
  const windows = new Map<string, bigint>([
    ["audio", 120n],
    ["video", 120n],
    ["catalog.json", 0n],
  ]);
  const delivered = new Map<string, Set<string>>();
  let now = 0;
  let lastMark: string | undefined;

  // Recent handles only, so the per-step snapshot stays cheap; older ones are long stale anyway.
  const keep = <T,>(xs: T[], x: T) => {
    xs.push(x);
    if (xs.length > 64) xs.shift();
  };
  const epochPool = () => (chance(0.1) ? epoch(fresh++) : epoch(1 + int(12)));
  const name = () => (chance(0.9) ? pick(["audio", "video", "catalog.json"]) : `t${int(200)}`);
  const windowOf = (n: string) => {
    if (!windows.has(n)) windows.set(n, pick([0n, 60n, 120n]));
    return windows.get(n)!;
  };
  // A subscription argument: issued (live, stale or any), a clone, a forged shape, a foreign
  // policy's handle, or junk. `issued` says whether this policy minted the reference.
  const subArg = (): { v: any; issued: boolean } => {
    const roll = r();
    if (subs.length && roll < 0.7) return { v: pick(subs), issued: true };
    if (subs.length && roll < 0.78) return { v: { ...pick(subs) }, issued: false };
    if (roll < 0.86) return { v: Object.freeze({ epoch: epochPool() }), issued: false };
    if (roll < 0.93) return { v: foreign, issued: false };
    return { v: pick([undefined, null, 0, "x", {}, []]), issued: false };
  };
  const trackArg = (): { v: any; issued: boolean } => {
    if (tracks.length && chance(0.85)) return { v: pick(tracks), issued: true };
    if (chance(0.5)) return { v: { name: name() }, issued: false };
    return { v: pick([undefined, null, 1, "audio"]), issued: false };
  };
  // Everything observable, as one cheap string; `full` keeps the objects for a readable diff.
  const state = () => {
    const i = p.inspect();
    const st = p.status;
    const fp = [
      i.now,
      i.incomplete,
      i.probe,
      i.paceRetryAt,
      i.candidates.map((c) => c.epoch + (c.available ? "+" : "-") + c.retryAt).join(","),
      i.bars.map((x) => x.epoch + "@" + x.until).join(","),
      i.tracks.map((t) => `${t.name}:${t.resubs}:${t.remembered}:${t.mark?.group}.${t.mark?.index}:${t.blockedUntil}`).join(","),
      st.playback, st.superseded, st.probing, st.budgetExhausted, st.olderStreamOnly, st.candidatesIncomplete,
      p.mark, p.acceptedEpoch, p.attemptCount, p.publishingEpoch,
      tracks.map((t) => `${t.current}${t.mark?.group}.${t.mark?.index}`).join(","),
    ].join("|");
    return { i, fp };
  };
  const full = (i: unknown) => JSON.parse(JSON.stringify(i, bigintSafe));
  for (let step = 0; step < STEPS; step++) {
    now += pick([0, 0, 0, 1, 2, 5, 50, 499, 1500, 3000, 10_000, 60_000]);
    p.tick(now);
    const before = state();
    let op = "";
    let refused = false; // the call declined; nothing may change
    let accepted = false;
    try {
      const roll = int(100);
      if (roll < 10) {
        op = "announce";
        if (chance(0.02)) {
          op = "announce-burst";
          for (let i = 0; i < 300; i++) p.announce(path(epoch(fresh++)));
        } else if (chance(0.05)) {
          refused = p.announce(pick(["alice/call", `bob/${scope.opaque}/${epoch(1)}`, 7 as any])) === "invalid";
        } else p.announce(path(epochPool()));
      } else if (roll < 15) {
        op = "withdraw";
        p.withdraw(path(epochPool()));
      } else if (roll < 18) {
        op = "reconcile";
        const n = chance(0.1) ? 300 : int(8);
        const set: string[] = [];
        for (let i = 0; i < n; i++) set.push(path(n === 300 ? epoch(1 + i) : epochPool()));
        p.reconcile(set);
      } else if (roll < 26) {
        op = "nextCandidate";
        p.nextCandidate(now);
      } else if (roll < 38) {
        op = "subscribe";
        const e = chance(0.7) ? p.nextCandidate(now) : pick([epochPool(), undefined as any]);
        const s = p.subscribe(e as string, now);
        if (s) keep(subs, s);
        else refused = true;
      } else if (roll < 50) {
        op = "authenticated";
        const a = subArg();
        const res = p.authenticated(a.v, chance(0.9) ? "bridge.tracks" : "video", now);
        accepted = res === "accepted";
        refused = res === false || res === "refreshed";
        if (!a.issued) assert.equal(res, false, "foreign/forged handle authenticated");
      } else if (roll < 55) {
        op = "probeEnded";
        const a = subArg();
        refused = !p.probeEnded(a.v, now);
        if (!a.issued) assert(refused, "foreign handle ended a probe");
      } else if (roll < 62) {
        op = "rejectCandidate";
        const a = subArg();
        const again = a.issued && reported.has(a.v);
        const ok = p.rejectCandidate(a.v, now);
        if (ok) reported.add(a.v);
        if (again) assert.equal(ok, false, "a repeated report was accepted");
        if (!a.issued) assert.equal(ok, false, "foreign handle rejected a candidate");
        refused = !ok;
      } else if (roll < 67) {
        op = "endInstance";
        const a = subArg();
        refused = !p.endInstance(a.v, now);
        if (!a.issued) assert(refused, "foreign handle ended the session");
      } else if (roll < 75) {
        op = "track";
        const a = subArg();
        const n = name();
        const t = p.track(a.v, n, windowOf(n));
        if (t instanceof TrackHandle) keep(tracks, t);
        else refused = true;
        if (!a.issued) assert(!(t instanceof TrackHandle), "foreign handle registered a track");
      } else if (roll < 90) {
        op = "frame";
        if (tracks.length) {
          const t = pick(tracks);
          const wasCurrent = t.current;
          const group = BigInt(int(400));
          const index = int(4);
          const res = t.frame({ group, index, authenticated: chance(0.92) });
          if (!wasCurrent) {
            assert.equal(res, "stale", "a stale handle judged a frame");
            refused = true;
          } else if (res === "deliver") {
            const key = `${t.name}|${group}|${index}`;
            const seen = delivered.get(p.mark!) ?? new Set<string>();
            assert(!seen.has(key), `delivered twice within mark ${p.mark}: ${key}`);
            seen.add(key);
            delivered.set(p.mark!, seen);
          }
        }
      } else if (roll < 95) {
        op = "trackFailure";
        const a = trackArg();
        const wasCurrent = a.issued && (a.v as TrackHandle).current;
        const res = p.trackFailure(a.v, now);
        if (!wasCurrent) assert.deepEqual(res, { kind: "ignored" }, "stale or foreign track failure acted");
        refused = res.kind === "ignored";
        if (!refused) assert.equal((a.v as TrackHandle).current, false, "handle survived its terminal failure");
      } else if (roll < 98) {
        op = "retryTrack";
        const a = subArg();
        const t = p.retryTrack(a.v, name(), now);
        if (t instanceof TrackHandle) keep(tracks, t);
        else refused = true;
      } else {
        op = "resumePublishing";
        p.resumePublishing(epoch(fresh++));
      }
    } catch (e) {
      if (e instanceof assert.AssertionError) throw new Error(`seed ${seed} step ${step} ${op}: ${e.message}`);
      // Only a type/range refusal may throw, and only before any change.
      if (!(e instanceof TypeError || e instanceof RangeError))
        throw new Error(`seed ${seed} step ${step} ${op}: unexpected ${e}`);
      refused = true;
    }

    const fail = (msg: string) => {
      throw new Error(`seed ${seed} step ${step} ${op}: ${msg}`);
    };
    const after = state();
    if (refused && after.fp !== before.fp)
      fail(`a refused call changed state: ${diff(full(before.i), full(after.i)).join("; ") || "(status or handle facts)"}`);

    // The mark never decreases and moves only on an accepted authenticated frame.
    const mark = p.mark;
    if (mark !== lastMark) {
      if (!accepted) fail(`mark moved without an acceptance: ${lastMark} -> ${mark}`);
      if (lastMark !== undefined && !(mark! > lastMark)) fail(`mark decreased: ${lastMark} -> ${mark}`);
      lastMark = mark;
    }
    // Collections stay within their caps; no bar, backoff or pace exceeds its maximum.
    const i = after.i;
    if (i.candidates.length > LIMITS.candidates) fail(`candidates ${i.candidates.length}`);
    if (i.tracks.length > LIMITS.tracksPerInstance) fail(`tracks ${i.tracks.length}`);
    if (p.attemptCount > LIMITS.probesPerWindow) fail(`attempts ${p.attemptCount}`);
    for (const t of i.tracks) {
      if (t.remembered > LIMITS.startsPerTrack) fail(`remembered ${t.remembered}`);
      if (t.resubs > LIMITS.resubscribesPerTrack) fail(`resubs ${t.resubs}`);
      if (t.blockedUntil > now + LIMITS.windowMs) fail(`track retry ${t.blockedUntil - now}`);
    }
    for (const b of i.bars) if (b.until > now + LIMITS.barMs) fail(`bar ${b.until - now}`);
    for (const c of i.candidates) if (c.retryAt > now + LIMITS.backoffCapMs) fail(`backoff ${c.retryAt - now}`);
    if (i.paceRetryAt > now + LIMITS.backoffCapMs) fail(`pace ${i.paceRetryAt - now}`);
    // Status facts agree with the internals they summarise.
    const st = p.status;
    if (st.budgetExhausted !== p.attemptCount >= LIMITS.probesPerWindow) fail("budgetExhausted");
    if (st.candidatesIncomplete !== i.incomplete) fail("candidatesIncomplete");
    if (st.olderStreamOnly) {
      if (i.incomplete) fail("olderStreamOnly with an incomplete view");
      if (p.acceptedEpoch !== undefined) fail("olderStreamOnly with playback");
      if (i.candidates.some((c) => c.available && c.epoch >= mark!))
        fail("olderStreamOnly with a candidate at or above the mark");
    }
    if ((st.playback === "ready") !== (p.acceptedEpoch !== undefined)) fail("playback");
  }
}

// Ten tests of SEEDS/10 seeds each, so no runner's per-test timeout is near (bun's is 5 s).
if (ONLY) test(`randomized policy invariants (seed ${ONLY} x ${STEPS} steps)`, () => run(Number(ONLY)));
else
  for (let block = 0; block < 10; block++) {
    const from = 1 + Math.floor((block * SEEDS) / 10);
    const to = Math.floor(((block + 1) * SEEDS) / 10);
    test(`randomized policy invariants (seeds ${from}-${to} x ${STEPS} steps)`, () => {
      for (let seed = from; seed <= to; seed++) run(seed);
    });
  }
