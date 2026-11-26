// Seeded, lifecycle-directed randomized check of the C1 reader policy.
//
// The generator is weighted by the current lifecycle state so that runs routinely reach
// acceptance, same-epoch end-and-re-accept, greater-epoch rotation, track failure through
// exhaustion and the clocked retry, overflow and reconcile. A share of steps stays fully random,
// with stale, cloned, forged, foreign and malformed arguments and junk field values.
//
// An independent model (not the policy's own state) tracks the live probe, the accepted session,
// which track handle is current, each name's outstanding grant, actual replacement start times,
// one-shot reports and the rejection fences. After every step it asserts the invariants the
// reviews established; a call the model says has no authority must change nothing, the clock
// included. There is no pre-call tick: advancing the clock is one of the generated actions.
//
// A failure prints `seed`, `step` and the operation; replay with RANDOM_SEED=<seed>. Reach
// counters are printed and each has an asserted minimum, so a shallower generator fails.
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
const num = (e: string) => parseInt(e.slice(0, 8), 16);
const scope = { profile: "moq-e2ee-01-wip", kid: 1, label: "alice", opaque: "A".repeat(22) };
const path = (e: string) => `alice/${scope.opaque}/${e}`;
const bigintSafe = (_k: string, v: unknown) => (typeof v === "bigint" ? `${v}n` : v);
function diff(a: any, b: any, at = ""): string[] {
  if (JSON.stringify(a, bigintSafe) === JSON.stringify(b, bigintSafe)) return [];
  if (a && b && typeof a === "object" && typeof b === "object" && !Array.isArray(a))
    return [...new Set([...Object.keys(a), ...Object.keys(b)])].flatMap((k) => diff(a[k], b[k], `${at}.${k}`));
  return [`${at}: ${JSON.stringify(a, bigintSafe)} -> ${JSON.stringify(b, bigintSafe)}`];
}

export const COUNTER_NAMES = [
  "probesIssued",
  "firstAcceptance",
  "sameEpochReaccept",
  "rotation",
  "deliveries",
  "replayRefused",
  "trackStarts",
  "replacementStarts",
  "trackExhaustion",
  "retryStarts",
  "overflowFull",
  "reconcileComplete",
  "lateReportsFenced",
  "staleRefused",
  "junkRefused",
] as const;
type Counters = Record<(typeof COUNTER_NAMES)[number], number>;
const zero = (): Counters => Object.fromEntries(COUNTER_NAMES.map((k) => [k, 0])) as Counters;

type SubModel = { sub: Subscription; seq: number; started: number; accepted: boolean; reported: boolean };
type NameModel = {
  handle: TrackHandle | undefined;
  grant: "none" | "resubscribe" | "retry";
  retryAt: number;
  starts: number[]; // actual charged replacement start times
  nextGroup: bigint;
};

export function run(seed: number, counters: Counters): void {
  const r = mulberry32(seed);
  const int = (n: number) => Math.floor(r() * n);
  const pick = <T,>(xs: readonly T[]): T => xs[int(xs.length)];
  const chance = (q: number) => r() < q;

  const own = chance(0.3) ? epoch(2) : undefined;
  const p = new InstancePolicy(scope, own);
  const other = new InstancePolicy(scope);
  other.announce(path(epoch(3)));
  const foreign = other.subscribe(epoch(3), 0) as Subscription;
  other.authenticated(foreign, "bridge.tracks", 1);

  // ---- the independent model
  let now = 0;
  let seq = 0;
  const subs: SubModel[] = [];
  const subModel = new Map<Subscription, SubModel>();
  let probe: SubModel | undefined;
  let session: SubModel | undefined;
  let mark: string | undefined;
  let markAcceptSeq = -1;
  let lastAcceptedEpoch: string | undefined;
  let names = new Map<string, NameModel>();
  const handleSession = new Map<TrackHandle, Subscription>();
  const handles: TrackHandle[] = [];
  let delivered = new Map<string, bigint[][]>(); // name -> [group, index] delivered in this mark
  let deliveredKeys = new Set<string>();
  const announced = new Set<number>();

  const keep = <T,>(xs: T[], x: T, n = 48) => {
    xs.push(x);
    if (xs.length > n) xs.shift();
  };
  const modelCurrent = (h: TrackHandle) =>
    session !== undefined &&
    handleSession.get(h) === session.sub &&
    names.get(h.name)?.handle === h;
  const syncProbeExpiry = () => {
    const pnow = p.inspect().now;
    if (probe && pnow - probe.started >= LIMITS.probeDeadlineMs) probe = undefined;
  };
  // Everything observable as one cheap string; the objects are kept for a readable diff.
  const state = () => {
    const i = p.inspect();
    const st = p.status;
    const h = handles.map((x) => `${x.current}${x.mark?.group}.${x.mark?.index}/${x.remembered}`).join(",");
    const fp = [
      i.now,
      i.incomplete,
      i.probe,
      i.paceRetryAt,
      i.candidates.map((c) => c.epoch + (c.available ? "+" : "-") + c.retryAt).join(","),
      i.bars.map((x) => x.epoch + "@" + x.until).join(","),
      i.tracks.map((t) => `${t.name}:${t.resubs}:${t.remembered}:${t.mark?.group}.${t.mark?.index}:${t.blockedUntil}`).join(","),
      st.playback, st.superseded, st.probing, st.budgetExhausted, st.olderStreamOnly, st.candidatesIncomplete,
      p.mark, p.acceptedEpoch, p.attemptCount, p.publishingEpoch, h,
    ].join("|");
    return { i, fp, obj: { i, st, h } };
  };

  const markNum = () => (mark === undefined ? 0 : num(mark));
  const pickEpochToAnnounce = () => {
    const roll = r();
    if (mark !== undefined && roll < 0.4) return mark; // re-accept the same epoch
    if (roll < 0.8) return epoch(markNum() + 1 + int(3)); // rotation
    if (roll < 0.9 && markNum() > 1) return epoch(1 + int(markNum() - 1)); // older
    return epoch(1 + int(40));
  };
  const announce = (e: string) => {
    const res = p.announce(path(e));
    if (res === "full") counters.overflowFull++;
    else {
      announced.delete(num(e));
      announced.add(num(e));
      // The test's own view of the active set stays bounded (oldest first out).
      if (announced.size > 400) announced.delete(announced.values().next().value!);
    }
    return res;
  };
  // A subscription argument and whether the model says it has authority for `role`.
  type Arg = { v: any; kind: "probe" | "session" | "stale" | "clone" | "forged" | "foreign" | "junk" };
  const subArg = (prefer?: "probe" | "session"): Arg => {
    if (prefer === "probe" && probe && chance(0.85)) return { v: probe.sub, kind: "probe" };
    if (prefer === "session" && session && chance(0.85)) return { v: session.sub, kind: "session" };
    const roll = r();
    if (subs.length && roll < 0.6) {
      const m = pick(subs);
      const kind = m === probe ? "probe" : m === session ? "session" : "stale";
      return { v: m.sub, kind };
    }
    if (subs.length && roll < 0.7) return { v: { ...pick(subs).sub }, kind: "clone" };
    if (roll < 0.8) return { v: Object.freeze({ epoch: epoch(1 + int(20)) }), kind: "forged" };
    if (roll < 0.9) return { v: foreign, kind: "foreign" };
    return { v: pick([undefined, null, 0, "x", {}, []]), kind: "junk" };
  };
  const NAMES = ["audio", "video", "catalog.json"];
  // Start `n` on the current session at `now`, checking the policy's answer against the model.
  const startTrack = (n: string, expect: (c: boolean, m: string) => void) => {
    const nm = names.get(n);
    const res = p.track(session!.sub, n, n === "catalog.json" ? 0n : 120n, undefined, now);
    if (nm?.handle && modelCurrent(nm.handle)) {
      expect((res as any).kind === "live", `healthy track restarted: ${JSON.stringify(res)}`);
      return false;
    }
    if (nm?.grant === "retry") {
      expect((res as any).reason === "retry_wait", "exhausted track started without retryTrack");
      return false;
    }
    expect(res instanceof TrackHandle, `track refused: ${JSON.stringify(res)}`);
    const h = res as TrackHandle;
    const m: NameModel = nm ?? { handle: undefined, grant: "none", retryAt: 0, starts: [], nextGroup: 0n };
    if (m.grant === "resubscribe") {
      m.starts = m.starts.filter((t) => t > now - LIMITS.windowMs);
      m.starts.push(now);
      expect(m.starts.length <= LIMITS.resubscribesPerTrack, `${m.starts.length} replacement starts of ${n} in a minute`);
      counters.replacementStarts++;
    }
    m.grant = "none";
    m.handle = h;
    names.set(n, m);
    handleSession.set(h, session!.sub);
    keep(handles, h, 16);
    counters.trackStarts++;
    return true;
  };
  const windowOf = (n: string) => (n === "catalog.json" ? 0n : 120n);

  for (let step = 0; step < STEPS; step++) {
    let op = "";
    let mustNotChange = false; // the model says this call has no authority / is malformed
    let accepted = false;
    const before = state();
    const fail = (msg: string): never => {
      throw new Error(`seed ${seed} step ${step} ${op}: ${msg}`);
    };
    const expect = (cond: boolean, msg: string) => {
      if (!cond) fail(msg);
    };
    // For a refused call inside a multi-call step: compare immediately around that call.
    const noChange = <T,>(what: string, f: () => T): T => {
      const b = state();
      let out: T;
      try {
        out = f();
      } catch (e) {
        if (!(e instanceof TypeError || e instanceof RangeError)) throw e;
        out = undefined as T;
      }
      const a = state();
      if (a.fp !== b.fp) fail(`${what} changed state: ${diff(b.obj, a.obj).join("; ")}`);
      return out;
    };
    try {
      const fullyRandom = chance(0.15);
      const roll = r();
      // ---- clock advance as an action (never a hidden pre-call tick)
      if (roll < 0.12) {
        op = "advance";
        now += pick([1, 5, 50, 400, 1499, 1500, 3000, 10_000, 60_000]);
        if (chance(0.5)) p.tick(now);
      } else if (fullyRandom) {
        // ---- fully random / malformed: every call here lacks authority or is malformed
        op = "random";
        mustNotChange = true;
        // Only arguments without authority here: re-pick until the handle is not current.
        let a = subArg();
        for (let k = 0; k < 6 && (a.kind === "probe" || a.kind === "session"); k++) a = subArg();
        if (a.kind === "probe" || a.kind === "session") a = { v: Object.freeze({ epoch: epoch(1) }), kind: "forged" };
        const which = int(10);
        if (process.env.RANDOM_TRACE) console.log(`step ${step} random which=${which} kind=${a.kind} now=${now} probe=${probe?.sub.epoch}`);
        const junkNow = chance(0.3) ? pick([NaN, -1, Infinity, "5"] as any[]) : now;
        try {
          if (which === 0) p.authenticated(a.v, chance(0.5) ? "bridge.tracks" : (pick(["video", 1, undefined]) as any), junkNow);
          else if (which === 1) p.probeEnded(a.v, junkNow);
          else if (which === 2) p.endInstance(a.v, junkNow);
          else if (which === 3) {
            // An issued, non-current probe keeps one late report: classify it with the model.
            const m = subModel.get(a.v);
            if (m && typeof junkNow === "number") {
              const fenced = (mark !== undefined && m.sub.epoch < mark) || (m.sub.epoch === mark && m.seq < markAcceptSeq);
              const allowed = !m.reported && !m.accepted && !fenced && junkNow >= p.inspect().now && junkNow < m.started + LIMITS.lateReportMs;
              const ok = p.rejectCandidate(a.v, junkNow);
              expect(ok === allowed, `random late report ${ok} allowed=${allowed}`);
              if (ok) {
                m.reported = true;
                mustNotChange = false;
              }
            } else p.rejectCandidate(a.v, junkNow);
          }
          else if (which === 4) p.track(a.v, pick(NAMES), 120n, undefined, typeof junkNow === "number" && junkNow >= 0 ? undefined : junkNow);
          else if (which === 5) p.retryTrack(a.v, pick(NAMES), junkNow);
          else if (which === 6) {
            mustNotChange = true;
            p.announce(pick(["alice/call", `bob/${scope.opaque}/${epoch(1)}`, 7, undefined] as any[]));
          } else if (which === 7) {
            mustNotChange = true;
            p.reconcile(pick([[42], [path(epoch(1)), undefined], "x", null, [path(epoch(1)), "alice/call"]] as any[]));
          } else if (which === 8) {
            mustNotChange = true;
            const h = handles.length ? pick(handles) : undefined;
            if (h) h.frame({ group: 7n, index: 0, authenticated: pick(["false", "true", 1, {}, null, undefined, Object(true)]) } as any);
          } else {
            mustNotChange = true;
            p.subscribe(pick([undefined, null, 7, "", epoch(1).toUpperCase()] as any[]), now);
          }
        } catch (e) {
          if (!(e instanceof TypeError || e instanceof RangeError)) throw e;
        }
        if (mustNotChange) a.kind === "junk" ? counters.junkRefused++ : counters.staleRefused++;
      } else if (probe) {
        // ---- a probe is live: mostly answer it in time
        const q = r();
        const p0 = probe;
        if (q < 0.6) {
          op = "authenticated(probe)";
          now += int(chance(0.85) ? 1200 : 2500);
          const res = p.authenticated(p0.sub, "bridge.tracks", now);
          const inTime = now - p0.started < LIMITS.probeDeadlineMs;
          expect(res === (inTime ? "accepted" : false), `probe acceptance ${res} inTime=${inTime}`);
          accepted = res === "accepted";
        } else if (q < 0.72) {
          op = "rejectCandidate(probe)";
          now += int(1400);
          const fenced = (mark !== undefined && p0.sub.epoch < mark) || (p0.sub.epoch === mark && p0.seq < markAcceptSeq);
          const ok = p.rejectCandidate(p0.sub, now);
          expect(ok === (!p0.reported && !p0.accepted && !fenced && now < p0.started + LIMITS.lateReportMs), `reject ${ok}`);
          if (ok) {
            p0.reported = true;
            if (probe === p0) probe = undefined;
          }
        } else if (q < 0.82) {
          op = "probeEnded(probe)";
          now += int(2000);
          const ok = p.probeEnded(p0.sub, now);
          const inTime = now - p0.started < LIMITS.probeDeadlineMs;
          expect(ok === inTime, `probeEnded ${ok} inTime=${inTime}`);
          probe = undefined;
        } else {
          op = "stale callbacks while probing";
          const a = subArg();
          if (a.kind !== "probe" && a.kind !== "session") {
            mustNotChange = true;
            counters.staleRefused++;
            now += int(3000);
            const w = int(4);
            if (w === 0) expect(p.endInstance(a.v, now) === false, "stale endInstance acted");
            else if (w === 1) expect(p.probeEnded(a.v, now) === false, "stale probeEnded acted");
            else if (w === 2) expect(p.authenticated(a.v, "bridge.tracks", now) === false, "stale authenticated acted");
            else expect((p.retryTrack(a.v, pick(NAMES), now) as any).kind === "stale", "stale retryTrack acted");
          }
        }
      } else if (session) {
        // ---- a session is accepted: tracks, frames, failures, retries, ends, rotations
        const q = r();
        const live = [...names.values()].filter((n) => n.handle && modelCurrent(n.handle));
        if (q < 0.34 && live.length) {
          op = "frame";
          const nm = pick(live);
          const h = nm.handle!;
          const past = delivered.get(h.name) ?? [];
          let group: bigint;
          let index: number;
          const replay = past.length && chance(0.3);
          if (replay) {
            const [g, i] = pick(past);
            group = g;
            index = Number(i);
          } else if (chance(0.8)) {
            group = nm.nextGroup;
            index = int(3);
            nm.nextGroup += BigInt(1 + int(40));
          } else {
            group = BigInt(int(Number(nm.nextGroup) + 1));
            index = int(3);
          }
          const res = h.frame({ group, index, authenticated: chance(0.95) });
          const key = `${h.name}|${group}|${index}`;
          if (res === "deliver") {
            expect(!deliveredKeys.has(key), `delivered twice within mark ${mark}: ${key}`);
            deliveredKeys.add(key);
            past.push([group, BigInt(index)]);
            if (past.length > 64) past.shift();
            delivered.set(h.name, past);
            counters.deliveries++;
          } else if (replay && (res === "duplicate" || res === "too_old")) counters.replayRefused++;
        } else if (q < 0.48) {
          op = "track";
          const n = pick(NAMES);
          now += int(50);
          if (chance(0.9)) {
            const nm = names.get(n);
            const refusedByModel = (nm?.handle && modelCurrent(nm.handle)) || nm?.grant === "retry";
            if (refusedByModel) mustNotChange = true;
            startTrack(n, expect);
          } else {
            const a = subArg();
            if (a.kind !== "session") {
              mustNotChange = true;
              counters.staleRefused++;
              const res = p.track(a.v, n, windowOf(n), undefined, undefined);
              expect(!(res instanceof TrackHandle) && (res as any).kind === "stale", "stale session started a track");
            }
          }
        } else if (q < 0.62 && live.length) {
          op = "trackFailure";
          const nm = pick(live);
          now += int(chance(0.85) ? 100 : 20_000);
          const res = p.trackFailure(nm.handle!, now);
          expect(res.kind !== "ignored", "a current handle's failure was ignored");
          expect(!nm.handle!.current, "handle survived its terminal failure");
          nm.handle = undefined;
          if (res.kind === "resubscribe") nm.grant = "resubscribe";
          else if (res.kind === "unavailable_retryable") {
            nm.grant = "retry";
            nm.retryAt = res.retryAt;
            counters.trackExhaustion++;
          }
          // a stale repeat of the same failure must be ignored
          const old = [...handles].reverse().find((h) => !modelCurrent(h));
          if (old) expect(noChange("stale track failure", () => p.trackFailure(old, now)).kind === "ignored", "stale track failure acted");
          // storm: replace at once and fail again, as a flapping subscription would
          const n = [...names.entries()].find(([, m]) => m === nm)![0];
          for (let k = 0; k < 8 && nm.grant === "resubscribe" && chance(0.75); k++) {
            now += 1 + int(200);
            if (!startTrack(n, expect)) break;
            now += 1 + int(200);
            const r2 = p.trackFailure(nm.handle!, now);
            nm.handle = undefined;
            if (r2.kind === "resubscribe") nm.grant = "resubscribe";
            else if (r2.kind === "unavailable_retryable") {
              nm.grant = "retry";
              nm.retryAt = r2.retryAt;
              counters.trackExhaustion++;
            } else expect(false, "storm failure ignored");
          }
        } else if (q < 0.7) {
          op = "retryTrack";
          const waiting = [...names.entries()].filter(([, m]) => m.grant === "retry");
          if (waiting.length) {
            const [n, m] = pick(waiting);
            if (chance(0.7)) now = Math.max(now, m.retryAt);
            else now += int(1000);
            const res = p.retryTrack(session.sub, n, now);
            if (now < m.retryAt) {
              mustNotChange = true;
              expect((res as any).reason === "retry_wait", "retry before retryAt");
            } else {
              expect(res instanceof TrackHandle, `retry refused ${JSON.stringify(res)}`);
              m.starts = m.starts.filter((t) => t > now - LIMITS.windowMs);
              m.starts.push(now);
              expect(m.starts.length <= LIMITS.resubscribesPerTrack, `${m.starts.length} starts of ${n} in a minute (retry)`);
              m.grant = "none";
              m.handle = res as TrackHandle;
              handleSession.set(m.handle, session.sub);
              keep(handles, m.handle, 16);
              counters.retryStarts++;
            }
          } else {
            // a retry on a healthy or never-failed name is refused, before the clock moves
            const n = pick(NAMES);
            now += int(100);
            mustNotChange = true;
            const res = p.retryTrack(session.sub, n, now);
            expect(!(res instanceof TrackHandle), "retry without an outstanding retry started a track");
          }
        } else if (q < 0.75) {
          op = "endInstance(session)";
          now += chance(0.6) ? int(100) : 10_000 + int(5000);
          expect(p.endInstance(session.sub, now) === true, "current session end refused");
          session = undefined;
        } else if (q < 0.83) {
          op = "announce greater";
          announce(epoch(markNum() + 1 + int(3)));
        } else if (q < 0.87) {
          op = "nextCandidate+subscribe (rotation probe)";
          now += int(200);
          const e = p.nextCandidate(now);
          syncProbeExpiry();
          if (e) {
            const s = p.subscribe(e, now);
            expect(!!s, "eligible candidate refused");
            const m: SubModel = { sub: s as Subscription, seq: seq++, started: now, accepted: false, reported: false };
            subs.push(m);
            subModel.set(m.sub, m);
            probe = m;
            counters.probesIssued++;
          }
        } else if (q < 0.9) {
          op = "reconcile (in session)";
          const active = [...announced].slice(chance(0.1) ? -400 : -24).map((e) => path(epoch(e)));
          const res = p.reconcile(active);
          announced.clear();
          for (const a of active) announced.add(num(a.split("/")[2]));
          if (res === "complete") counters.reconcileComplete++;
        } else {
          op = "late report of an old probe";
          const old = subs.filter((m) => m !== probe && !m.accepted);
          if (old.length) {
            const m = pick(old);
            now += int(500);
            const fenced = (mark !== undefined && m.sub.epoch < mark) || (m.sub.epoch === mark && m.seq < markAcceptSeq);
            const allowed = !m.reported && !fenced && now < m.started + LIMITS.lateReportMs;
            if (!allowed) mustNotChange = true;
            const ok = p.rejectCandidate(m.sub, now);
            expect(ok === allowed, `late report ${ok} allowed=${allowed}`);
            if (ok) m.reported = true;
            if (fenced) counters.lateReportsFenced++;
          }
        }
      } else {
        // ---- idle: announce, probe, overflow and reconcile
        const q = r();
        if (q < 0.25) {
          op = "announce";
          announce(pickEpochToAnnounce());
        } else if (q < 0.8) {
          op = "nextCandidate+subscribe";
          now += int(50);
          const e = p.nextCandidate(now);
          syncProbeExpiry();
          if (e) {
            const s = p.subscribe(e, now);
            expect(!!s, "eligible candidate refused");
            const m: SubModel = { sub: s as Subscription, seq: seq++, started: now, accepted: false, reported: false };
            subs.push(m);
            subModel.set(m.sub, m);
            probe = m;
            counters.probesIssued++;
          } else if (chance(0.3)) {
            const bad = epoch(markNum() + 50);
            expect(noChange("unannounced subscribe", () => p.subscribe(bad, now)) === false, "unannounced epoch subscribed");
            counters.staleRefused++;
          }
        } else if (q < 0.86) {
          op = "withdraw";
          const e = announced.size ? pick([...announced]) : 1;
          p.withdraw(path(epoch(e)));
          announced.delete(e);
        } else if (q < 0.875) {
          op = "overflow burst";
          const base = markNum() + 1000 + int(1000);
          for (let i = 0; i < 300; i++) announce(epoch(base + i));
        } else {
          op = "reconcile";
          const active = [...announced].slice(chance(0.1) ? -400 : -24).map((e) => path(epoch(e)));
          const res = p.reconcile(active);
          announced.clear();
          for (const a of active) announced.add(num(a.split("/")[2]));
          if (res === "complete") counters.reconcileComplete++;
        }
      }
    } catch (e) {
      if (e instanceof Error && e.message.startsWith(`seed ${seed} step`)) throw e;
      if (e instanceof assert.AssertionError) fail(e.message);
      if (!(e instanceof Error)) fail(`unexpected ${String(e)}`);
      if (!(e instanceof TypeError || e instanceof RangeError)) fail(`unexpected ${e}`);
      mustNotChange = true;
    }

    // ---- model bookkeeping that follows from results
    if (accepted && probe) {
      const m = probe;
      m.accepted = true;
      const e = m.sub.epoch;
      if (mark === undefined) counters.firstAcceptance++;
      else if (e > mark) counters.rotation++;
      else if (e === mark && lastAcceptedEpoch === e) counters.sameEpochReaccept++;
      if (e !== mark) {
        names = new Map();
        delivered = new Map();
        deliveredKeys = new Set();
        markAcceptSeq = -1;
      }
      mark = e;
      markAcceptSeq = Math.max(markAcceptSeq, m.seq);
      lastAcceptedEpoch = e;
      session = m;
      probe = undefined;
    }
    syncProbeExpiry();

    const after = state();
    if (mustNotChange && after.fp !== before.fp)
      fail(`a call without authority changed state: ${diff(before.obj, after.obj).join("; ")}`);

    // ---- invariants against the independent model (plain checks: messages only on failure)
    if (p.mark !== mark) fail(`mark ${p.mark} != model ${mark}`);
    if (p.acceptedEpoch !== session?.sub.epoch) fail(`accepted ${p.acceptedEpoch} != model ${session?.sub.epoch}`);
    if ((after.i.probe !== undefined) !== (probe !== undefined)) fail(`probe ${after.i.probe} vs model ${probe?.sub.epoch}`);
    for (const h of handles) {
      const mc = modelCurrent(h);
      if (h.current !== mc) fail(`handle ${h.name} current=${h.current} model=${mc}`);
    }
    const i = after.i;
    const pnow = i.now;
    if (i.candidates.length > LIMITS.candidates) fail(`candidates ${i.candidates.length}`);
    if (i.tracks.length > LIMITS.tracksPerInstance) fail(`tracks ${i.tracks.length}`);
    if (p.attemptCount > LIMITS.probesPerWindow) fail(`attempts ${p.attemptCount}`);
    if (i.bars.length > 2 * LIMITS.probesPerWindow) fail(`bars ${i.bars.length}`);
    for (const t of i.tracks) {
      if (t.remembered > LIMITS.startsPerTrack) fail(`remembered ${t.remembered}`);
      if (t.resubs > LIMITS.resubscribesPerTrack) fail(`resubs ${t.resubs}`);
      if (t.blockedUntil > pnow + LIMITS.windowMs) fail(`track retry ${t.blockedUntil - pnow}`);
    }
    for (const x of i.bars) if (x.until > pnow + LIMITS.barMs) fail(`bar ${x.until - pnow}`);
    let below = false;
    let atOrAbove = false;
    for (const c of i.candidates) {
      if (c.retryAt > pnow + LIMITS.backoffCapMs) fail(`backoff ${c.retryAt - pnow}`);
      if (c.available && mark !== undefined) c.epoch < mark ? (below = true) : (atOrAbove = true);
    }
    if (i.paceRetryAt > pnow + LIMITS.backoffCapMs) fail(`pace ${i.paceRetryAt - pnow}`);
    // status, both directions
    const st = p.status;
    expect(st.inviteNeeded === false, "inviteNeeded");
    expect((st.playback === "ready") === (session !== undefined), "playback");
    expect(st.superseded === (session !== undefined && own !== undefined && session.sub.epoch > own), "superseded");
    expect((st.probing === "probing") === (probe !== undefined), "probing");
    expect(st.budgetExhausted === p.attemptCount >= LIMITS.probesPerWindow, "budgetExhausted");
    expect(st.candidatesIncomplete === i.incomplete, "candidatesIncomplete");
    const older = session === undefined && !i.incomplete && mark !== undefined && below && !atOrAbove;
    expect(st.olderStreamOnly === older, `olderStreamOnly ${st.olderStreamOnly} model ${older}`);
  }
}

// Minimum reach per block (20 seeds x 2000 steps by default), scaled to the configured size.
const MINIMA: Partial<Counters> = {
  probesIssued: 2000,
  firstAcceptance: 18,
  sameEpochReaccept: 150,
  rotation: 150,
  deliveries: 3000,
  replayRefused: 500,
  trackStarts: 1000,
  replacementStarts: 300,
  trackExhaustion: 3,
  retryStarts: 3,
  overflowFull: 100,
  reconcileComplete: 50,
  lateReportsFenced: 50,
  staleRefused: 1000,
  junkRefused: 200,
};

const total = zero();
const blocks = ONLY ? [[Number(ONLY), Number(ONLY)]] : Array.from({ length: 10 }, (_, b) => [1 + Math.floor((b * SEEDS) / 10), Math.floor(((b + 1) * SEEDS) / 10)]);
for (const [from, to] of blocks) {
  test(`lifecycle-directed randomized invariants (seeds ${from}-${to} x ${STEPS} steps)`, () => {
    const c = zero();
    for (let seed = from; seed <= to; seed++) run(seed, c);
    for (const k of COUNTER_NAMES) total[k] += c[k];
    if (ONLY) return;
    const scale = ((to - from + 1) * STEPS) / (20 * 2000);
    for (const [k, min] of Object.entries(MINIMA))
      assert(c[k as keyof Counters] >= Math.floor(min! * scale), `reach ${k}=${c[k as keyof Counters]} below ${Math.floor(min! * scale)} in seeds ${from}-${to}`);
  });
}
test("reach counters (printed)", () => {
  console.log(`reach over ${ONLY ? 1 : SEEDS} seeds x ${STEPS} steps: ${JSON.stringify(total)}`);
});
