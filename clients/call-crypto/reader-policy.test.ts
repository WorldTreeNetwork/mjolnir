import { test } from "node:test";
import assert from "node:assert/strict";
import { InstancePolicy, GroupTracker, TrackHandle } from "./reader-policy.ts";
import type { Subscription } from "./reader-policy.ts";
const epoch = (n: number) => `${n.toString(16).padStart(8, "0")}-0000-7000-8000-000000000000`;
const E1 = epoch(1),
  E2 = epoch(2),
  E3 = epoch(3),
  FAST = epoch(0xffffffff);
const scope = { profile: "moq-e2ee-01-wip", kid: 1, label: "alice", opaque: "A".repeat(22) };
const path = (e: string) => `alice/${scope.opaque}/${e}`;
const make = (own?: string) => new InstancePolicy(scope, own);
// subscribe() returns the opaque handle of that one manifest subscription attempt.
function start(p: any, e: string, now = 0): any {
  p.announce(path(e));
  assert.equal(p.nextCandidate(now), e);
  const s = must(p.subscribe(e, now));
  assert(s);
  return s;
}
// Returns the accepted session's handle.
function accept(p: any, e = E1, now = 0): any {
  const s = start(p, e, now);
  assert.equal(p.authenticated(s, "bridge.tracks", now + 1), "accepted");
  return s;
}
// A subscribe() result that must have started (narrows `Subscription | false`).
function must(s: Subscription | false): Subscription {
  assert(s, "probe did not start");
  return s;
}
// Report `n` terminal failures of `name`, each on its own (replacement) track subscription.
function failN(p: any, s: any, name: string, n: number, now: number, window = 120n) {
  for (let i = 0; i < n; i++) {
    const h = tracker(p, s, name, window);
    assert.equal(p.trackFailure(h, now).kind, "resubscribe");
  }
}
// A handle-shaped object this policy never issued.
const forged = (e: string): any => Object.freeze({ epoch: e });
const frame = (g: any, group: bigint, index = 0, authenticated = true) =>
  g.frame({ group, index, authenticated });
// track(session, ...) returns the handle of one track subscription, or a track-scoped refusal.
function tracker(p: any, s: any, name: string, window = 120n, mirror?: unknown): TrackHandle {
  const t = p.track(s, name, window, mirror);
  assert(t instanceof TrackHandle, `track ${name} refused: ${JSON.stringify(t)}`);
  return t;
}
// The accepted session ends and the relay announces the same epoch again (or an honest reconnect).
// Returns the new session handle.
function bounce(p: any, s: any, e: string, now: number): any {
  assert(p.endInstance(s, now));
  p.announce(path(e));
  assert.equal(p.nextCandidate(now), e);
  const again = must(p.subscribe(e, now));
  assert(again);
  assert.equal(p.authenticated(again, "bridge.tracks", now + 1), "accepted");
  return again;
}
// Regression table: every named row is run independently in both red and green transcripts.
const rows: [string, () => void][] = [
  [
    "I01 announcement alone cannot move mark",
    () => {
      const p = make();
      p.announce(path(E2));
      assert.equal(p.mark, undefined);
      assert.equal(p.acceptedEpoch, undefined);
    },
  ],
  [
    "I02 candidates tried greatest first",
    () => {
      const p = make();
      p.announce(path(E1));
      p.announce(path(E2));
      assert.equal(p.nextCandidate(0), E2);
    },
  ],
  [
    "I03 forged greater authentication failure falls through",
    () => {
      const p = make();
      p.announce(path(E1));
      const s2 = start(p, E2);
      assert(p.rejectCandidate(s2, 1));
      assert.equal(p.mark, undefined);
      assert.equal(p.nextCandidate(2), E1);
      const s1 = must(p.subscribe(E1, 2));
      assert(s1);
      assert(p.authenticated(s1, "bridge.tracks", 3));
      assert.equal(p.mark, E1);
    },
  ],
  [
    "I04 re-served older instance does not roll back",
    () => {
      const p = make();
      const s = accept(p, E2);
      p.announce(path(E1));
      assert.equal(p.nextCandidate(2), undefined);
      assert.equal(p.subscribe(E1, 2), false);
      assert.equal(p.authenticated(forged(E1), "bridge.tracks", 3), false);
      p.endInstance(s, 3);
      p.withdraw(path(E2));
      assert.equal(p.subscribe(E1, 4), false);
      assert.equal(p.authenticated(forged(E1), "bridge.tracks", 5), false);
      assert.equal(p.mark, E2);
      assert.equal(p.acceptedEpoch, undefined);
    },
  ],
  [
    "I05 plaintext wrong label and wrong opaque refused",
    () => {
      const p = make();
      for (const v of ["alice/call", `bob/${scope.opaque}/${E1}`, `alice/${"B".repeat(22)}/${E1}`])
        assert.equal(p.announce(v), "invalid");
      assert.equal(p.nextCandidate(0), undefined);
    },
  ],
  [
    "I06 timeout retries after 3 seconds and counts budget",
    () => {
      const p = make();
      start(p, E1);
      p.tick(1500);
      assert.equal(p.attemptCount, 1);
      assert.equal(p.nextCandidate(4499), undefined);
      assert.equal(p.nextCandidate(4500), E1);
      assert(p.subscribe(E1, 4500));
      assert.equal(p.attemptCount, 2);
    },
  ],
  [
    "I07 successive timeout doubles backoff",
    () => {
      const p = make();
      start(p, E1);
      p.tick(1500);
      assert(p.subscribe(E1, 4500));
      p.tick(6000);
      assert.equal(p.nextCandidate(11999), undefined);
      assert.equal(p.nextCandidate(12000), E1);
    },
  ],
  [
    "I08 probing timeout or authentication failure keeps accepted playback",
    () => {
      const p = make();
      accept(p);
      start(p, E2, 10);
      p.tick(1510);
      assert.equal(p.acceptedEpoch, E1);
      assert.equal(p.mark, E1);
      p.announce(path(E3));
      const s3 = must(p.subscribe(E3, 1520));
      assert(s3);
      assert(p.rejectCandidate(s3, 1521));
      assert.equal(p.acceptedEpoch, E1);
      assert.equal(p.mark, E1);
      assert.equal(p.status.playback, "ready");
    },
  ],
  [
    "I09 twelve attempt rolling budget",
    () => {
      const p = make();
      for (let i = 1; i <= 12; i++) {
        const e = epoch(i);
        p.rejectCandidate(start(p, e, i * 2), i * 2 + 1);
      }
      p.announce(path(FAST));
      assert.equal(p.nextCandidate(30), undefined);
      assert.equal(p.status.budgetExhausted, true);
      assert.equal(p.status.probing, "idle");
      assert.deepEqual(p.states, ["unavailable_retryable"]);
      assert.equal(p.nextCandidate(60003), FAST);
    },
  ],
  [
    "I10 authentication bars candidate for sixty seconds",
    () => {
      const p = make();
      p.rejectCandidate(start(p, E1), 1);
      assert.equal(p.nextCandidate(60000), undefined);
      assert.equal(p.nextCandidate(60001), E1);
    },
  ],
  [
    "I11 noncanonical epochs rejected",
    () => {
      const p = make();
      for (const e of [
        epoch(10).toUpperCase(),
        E1.replace("-7000-", "-4000-"),
        E1.replace("-8000-", "-0000-"),
        "nonsense",
      ])
        assert.equal(p.announce(path(e)), "invalid");
    },
  ],
  [
    "I12 ended selected instance keeps mark",
    () => {
      const p = make();
      const s = accept(p, E2);
      p.announce(path(E1));
      p.endInstance(s, 1);
      p.withdraw(path(E2));
      assert.equal(p.mark, E2);
      assert.equal(p.nextCandidate(2), undefined);
      assert.equal(p.status.olderStreamOnly, true);
      assert.deepEqual(p.states, ["older_stream_only"]);
    },
  ],
  [
    "I13 second device supersedes publisher only after authentication",
    () => {
      const p = make(E1);
      const s = start(p, E2);
      assert.equal(p.status.superseded, false);
      p.authenticated(s, "bridge.tracks", 1);
      assert.equal(p.status.superseded, true);
      p.resumePublishing(E3);
      assert.equal(p.publishingEpoch, E3);
      assert.equal(p.mark, E2);
      assert.equal(p.status.superseded, false);
    },
  ],
  [
    "I14 reload new page loses credential and mark",
    () => {
      const p = make();
      accept(p, E2);
      const blank = new InstancePolicy();
      assert.equal(blank.status.inviteNeeded, true);
      assert.deepEqual(blank.states, ["invite_needed"]);
      assert.equal(blank.mark, undefined);
      assert.equal(make().mark, undefined);
      assert.equal(p.mark, E2);
    },
  ],
  [
    "I15 fast clock blocks honest lower until explicit page reset",
    () => {
      const p = make();
      const s = accept(p, FAST);
      p.announce(path(E2));
      assert.equal(p.nextCandidate(2), undefined);
      p.endInstance(s, 2);
      p.withdraw(path(FAST));
      assert.equal(p.nextCandidate(3), undefined);
      assert.equal(p.subscribe(E2, 4), false);
      assert.equal(p.status.olderStreamOnly, true);
      assert.equal(p.mark, FAST);
      const fresh = make();
      accept(fresh, E2, 5);
      assert.equal(fresh.mark, E2);
    },
  ],
  [
    "I16 recorded greater manifest supersedes after each resume",
    () => {
      const p = make(E1);
      const s = accept(p, FAST);
      for (const e of [E2, E3]) {
        p.resumePublishing(e);
        assert.equal(p.authenticated(s, "bridge.tracks", 10), "refreshed");
        assert.equal(p.status.superseded, true);
      }
      assert.equal(p.mark, FAST);
    },
  ],
  [
    "I17 track failure keeps instance generation mark and mirror",
    () => {
      const p = make();
      const s = accept(p);
      const g = tracker(p, s, "video");
      frame(g, 20n, 1);
      const mirror = g.mirror;
      const action = p.trackFailure(g, 2);
      assert.deepEqual(action, {
        kind: "resubscribe",
        epoch: E1,
        track: "video",
        preserveMark: true,
        preserveMirror: true,
      });
      assert.equal(p.acceptedEpoch, E1);
      assert.equal(p.mark, E1);
      const again = tracker(p, s, "video");
      assert.equal(again.mirror, mirror);
      assert.equal(again.mark?.index, 1);
      assert.equal(g.current, false);
    },
  ],
  [
    "I18 six resubscriptions then unavailable",
    () => {
      const p = make();
      const s = accept(p);
      let h = tracker(p, s, "audio");
      for (let i = 0; i < 6; i++) {
        assert.equal(p.trackFailure(h, i + 2).kind, "resubscribe");
        h = tracker(p, s, "audio");
      }
      assert.equal(p.trackFailure(h, 8).kind, "unavailable_retryable");
      assert.equal(p.acceptedEpoch, E1);
    },
  ],
  [
    "I19 resubscription budget recovers after rolling minute",
    () => {
      const p = make();
      const s = accept(p);
      failN(p, s, "audio", 6, 2);
      assert.equal(p.trackFailure(tracker(p, s, "audio"), 3).kind, "unavailable_retryable");
      assert.equal((p.retryTrack(s, "audio", 60001) as any).reason, "retry_wait");
      const h = p.retryTrack(s, "audio", 60002);
      assert(h instanceof TrackHandle);
      assert.equal(p.trackFailure(h, 60002).kind, "resubscribe");
    },
  ],
  [
    "I20 resubscription budget is per track",
    () => {
      const p = make();
      const s = accept(p);
      const a = tracker(p, s, "audio");
      const v = tracker(p, s, "video", 0n);
      for (let i = 0; i < 6; i++) p.trackFailure(a, 2);
      assert.equal(p.trackFailure(v, 3).kind, "resubscribe");
    },
  ],
  [
    "I21 only manifest accepts instance",
    () => {
      const p = make();
      const s = start(p, E1);
      assert.equal(p.authenticated(s, "video", 1), false);
      assert.equal(p.mark, undefined);
      assert(p.authenticated(s, "bridge.tracks", 2));
    },
  ],
  [
    "I22 late frame after probe timeout cannot accept",
    () => {
      const p = make();
      const s = start(p, E1);
      assert.equal(p.authenticated(s, "bridge.tracks", 1501), false);
      assert.equal(p.mark, undefined);
    },
  ],
  [
    "I23 timeout starts at subscription not announcement",
    () => {
      const p = make();
      p.announce(path(E1));
      assert.equal(p.nextCandidate(0), E1);
      const s = must(p.subscribe(E1, 10000));
      assert(s);
      assert(p.authenticated(s, "bridge.tracks", 11499));
    },
  ],
  [
    "I24 invalid and backward policy clocks refused",
    () => {
      const p = make();
      assert.throws(() => p.nextCandidate(-1), RangeError);
      p.nextCandidate(10);
      assert.throws(() => p.nextCandidate(9), RangeError);
      assert.throws(() => p.tick(NaN), RangeError);
    },
  ],
  [
    "I25 immutable credential scope validation",
    () => {
      assert.throws(() => new InstancePolicy({ ...scope, profile: "other" }), TypeError);
      assert.throws(() => new InstancePolicy({ ...scope, kid: NaN }), TypeError);
      const local = { ...scope };
      const p = new InstancePolicy(local);
      local.label = "bob";
      assert.equal(p.announce(path(E1)), "ok");
      assert.equal(p.scope?.label, "alice");
    },
  ],
  [
    "I26 accepted failure is not candidate rejection",
    () => {
      const p = make();
      const s = accept(p);
      const h = tracker(p, s, "audio");
      assert.equal(p.rejectCandidate(s, 2), false);
      assert.equal(p.acceptedEpoch, E1);
      assert.equal(p.trackFailure(h, 3).kind, "resubscribe");
    },
  ],
  [
    "I27 withdrawal reannouncement cannot clear refusal or backoff",
    () => {
      const p = make();
      p.rejectCandidate(start(p, E1), 1);
      p.withdraw(path(E1));
      p.announce(path(E1));
      assert.equal(p.nextCandidate(2), undefined);
      const q = make();
      start(q, E1);
      q.tick(1500);
      q.withdraw(path(E1));
      q.announce(path(E1));
      assert.equal(q.nextCandidate(1501), undefined);
    },
  ],
  [
    "I28 announcement flood has bounded candidate memory",
    () => {
      const p = make();
      for (let i = 1; i <= 256; i++) assert.equal(p.announce(path(epoch(i))), "ok");
      assert.equal(p.announce(path(epoch(257))), "full");
      assert(p.candidateCount <= 256);
    },
  ],
  [
    "I29 retracting announcement does not stop accepted media",
    () => {
      const p = make();
      accept(p);
      p.withdraw(path(E1));
      assert.equal(p.acceptedEpoch, E1);
      assert.equal(p.mark, E1);
    },
  ],
  [
    "I30 stale retired subscription failure cannot consume new epoch budget",
    () => {
      const p = make();
      const s1 = accept(p);
      const old = tracker(p, s1, "audio");
      const s2 = start(p, E2, 5);
      p.authenticated(s2, "bridge.tracks", 6);
      assert.deepEqual(p.trackFailure(old, 7), { kind: "ignored" });
      failN(p, s2, "audio", 6, 8);
    },
  ],
  [
    "G01 authentic first frame advances pair",
    () => {
      const g = new GroupTracker(0n);
      assert.equal(frame(g, 10n, 2), "deliver");
      assert.deepEqual(g.mark, { group: 10n, index: 2 });
    },
  ],
  [
    "G02 higher authenticated group advances pair",
    () => {
      const g = new GroupTracker(0n);
      frame(g, 10n, 3);
      frame(g, 20n, 0);
      assert.deepEqual(g.mark, { group: 20n, index: 0 });
    },
  ],
  [
    "G03 equal group continues strictly above saved index",
    () => {
      const g = new GroupTracker(0n);
      frame(g, 10n, 2);
      assert.equal(frame(g, 10n, 3), "deliver");
      assert.equal(g.mark?.index, 3);
    },
  ],
  [
    "G04 frame replay cannot reopen",
    () => {
      const g = new GroupTracker(0n);
      frame(g, 10n, 2);
      assert.equal(frame(g, 10n, 2), "duplicate");
      assert.equal(frame(g, 10n, 1), "duplicate");
    },
  ],
  [
    "G05 manifest catalog zero window rejects older group",
    () => {
      const g = new GroupTracker(0n);
      frame(g, 20n);
      assert.equal(frame(g, 10n), "too_old");
      assert.equal(g.mark?.group, 20n);
    },
  ],
  [
    "G06 forged high frame never advances mark",
    () => {
      const g = new GroupTracker(120n);
      frame(g, 20n, 1);
      assert.equal(frame(g, 999999n, 0, false), "unauthenticated");
      assert.deepEqual(g.mark, { group: 20n, index: 1 });
    },
  ],
  [
    "G07 media accepts unseen older start within 120ms",
    () => {
      const g = new GroupTracker(120n);
      frame(g, 200n);
      assert.equal(frame(g, 100n), "deliver");
      assert.deepEqual(g.mark, { group: 200n, index: 0 });
    },
  ],
  [
    "G08 window boundary inclusive and older refused",
    () => {
      const g = new GroupTracker(120n);
      frame(g, 200n);
      assert.equal(frame(g, 80n), "deliver");
      assert.equal(frame(g, 79n), "too_old");
    },
  ],
  [
    "G09 late group frame index remembered independently",
    () => {
      const g = new GroupTracker(120n);
      frame(g, 200n, 4);
      frame(g, 100n, 1);
      assert.equal(frame(g, 100n, 2), "deliver");
      assert.equal(frame(g, 100n, 1), "duplicate");
      assert.deepEqual(g.mark, { group: 200n, index: 4 });
    },
  ],
  [
    "G10 caller mirror is attached at creation and lives as long as the mark",
    () => {
      const p = make();
      const s = accept(p);
      const mirror = {};
      const g = tracker(p, s, "catalog", 0n, mirror);
      assert.equal(g.mirror, mirror);
      frame(g, 20n, 1);
      assert.equal(p.trackFailure(g, 2).kind, "resubscribe");
      const again = tracker(p, s, "catalog", 0n, {});
      assert.equal(again.mirror, mirror);
      assert.equal(frame(again, 20n, 2), "deliver");
      assert.deepEqual(again.mark, { group: 20n, index: 2 });
    },
  ],
  [
    "G11 frame gap resumes at authenticated transport index",
    () => {
      const g = new GroupTracker(0n);
      frame(g, 20n, 1);
      assert.equal(frame(g, 20n, 5), "deliver");
      assert.equal(g.mark?.index, 5);
    },
  ],
  [
    "G12 group identities keep uint64 precision",
    () => {
      const g = new GroupTracker(0n);
      const v = 9007199254740993n;
      frame(g, v);
      assert.equal(frame(g, v + 1n), "deliver");
      assert.equal(g.mark?.group, v + 1n);
    },
  ],
  [
    "G13 invalid nonce identities refused",
    () => {
      const g = new GroupTracker(0n);
      for (const index of [-1, NaN, 2 ** 32, 1.5])
        assert.throws(() => frame(g, 0n, index), RangeError);
      assert.throws(() => frame(g, -1n), RangeError);
      assert.throws(() => frame(g, 2n ** 64n), RangeError);
      assert.throws(() => new GroupTracker(-1n), RangeError);
    },
  ],
  [
    "G14 dense starts have bounded replay memory",
    () => {
      const g = new GroupTracker(1000n);
      for (let i = 0; i < 200; i++) frame(g, BigInt(i));
      assert(g.remembered <= 128);
      assert.equal(frame(g, 0n), "too_old");
    },
  ],
  [
    "G15 per instance and track marks do not mix",
    () => {
      const p = make();
      const s1 = accept(p);
      const a = tracker(p, s1, "audio");
      frame(a, 20n);
      assert.equal(tracker(p, s1, "video", 0n).mark, undefined);
      const s2 = start(p, E2, 5);
      p.authenticated(s2, "bridge.tracks", 6);
      assert.equal(tracker(p, s2, "audio").mark, undefined);
      assert.equal(a.mark?.group, 20n);
      assert.equal(frame(a, 40n), "stale");
    },
  ],
  [
    "G16 changing window keeps the first window and mark",
    () => {
      const p = make();
      const s = accept(p);
      const a = tracker(p, s, "audio", 120n);
      frame(a, 200n);
      const again = tracker(p, s, "audio", 0n);
      assert.equal(again.window, 120n);
      assert.equal(frame(again, 100n), "deliver");
      assert.deepEqual(again.mark, { group: 200n, index: 0 });
    },
  ],
  [
    "I31 same-epoch re-acceptance keeps group/frame marks and mirror (bounce then replay)",
    () => {
      const p = make();
      const s = accept(p, E1);
      const mirror = {};
      const audio = tracker(p, s, "audio", 120n, mirror);
      for (let g = 0n; g <= 1000n; g += 20n) assert.equal(frame(audio, g), "deliver");
      assert.equal(frame(audio, 1000n), "duplicate");
      p.tick(10);
      const s2 = bounce(p, s, E1, 20);
      assert.equal(p.mark, E1);
      const again = tracker(p, s2, "audio", 120n);
      assert.equal(again.mirror, mirror);
      assert.notEqual(frame(again, 0n), "deliver");
      assert.equal(frame(again, 1000n), "duplicate");
      assert.deepEqual(again.mark, { group: 1000n, index: 0 });
    },
  ],
  [
    "I32 same-epoch re-acceptance keeps the resubscribe budget",
    () => {
      const p = make();
      const s = accept(p, E1);
      failN(p, s, "audio", 6, 2);
      assert.equal(p.trackFailure(tracker(p, s, "audio"), 3).kind, "unavailable_retryable");
      p.tick(4);
      const s2 = bounce(p, s, E1, 5);
      // The exhausted budget and its retry time survive the bounce.
      assert.deepEqual(p.track(s2, "audio", 120n), {
        kind: "unavailable_retryable",
        track: "audio",
        reason: "retry_wait",
        retryAt: 60002,
      });
    },
  ],
  [
    "I33 accepting a greater epoch releases the older epoch's trackers and budgets",
    () => {
      const p = make();
      const s1 = accept(p, E1);
      const a = tracker(p, s1, "audio");
      tracker(p, s1, "video", 0n);
      frame(a, 20n);
      assert.equal(p.trackFailure(a, 2).kind, "resubscribe");
      failN(p, s1, "audio", 5, 2);
      assert.equal(p.trackCount, 2);
      const s2 = start(p, E2, 5);
      assert(p.authenticated(s2, "bridge.tracks", 6));
      assert.equal(p.trackCount, 0);
      assert.equal(tracker(p, s2, "audio").mark, undefined);
      failN(p, s2, "audio", 6, 7);
    },
  ],
  [
    "I34 probe ended by the transport backs off like a timeout, never retracts",
    () => {
      // A misrouted endInstance on a live probe is not a retraction and does not end the probe.
      const q = make();
      q.announce(path(E1));
      const q3 = start(q, E3, 0);
      assert.equal(q.endInstance(q3, 0), false);
      assert.equal(q.nextCandidate(1), undefined);
      assert.equal(q.status.probing, "probing");
      q.tick(1500);
      assert.equal(q.nextCandidate(1500), E1);
      // probeEnded: backoff from the end, no bar, fall through to the real candidate.
      const p = make();
      p.announce(path(E1));
      const p3 = start(p, E3, 0);
      assert(p.probeEnded(p3, 0));
      p.announce(path(E3));
      assert.equal(p.nextCandidate(1), E1);
      const s1 = must(p.subscribe(E1, 1));
      assert.equal(p.authenticated(s1, "bridge.tracks", 2), "accepted");
      assert.equal(p.nextCandidate(2999), undefined);
      assert.equal(p.nextCandidate(3000), E3);
      assert.equal(p.attemptCount, 2);
      assert.equal(p.probeEnded(forged(E2), 3001), false);
      assert.equal(p.probeEnded(p3, 3001), false);
    },
  ],
  [
    "I35 transport end of the accepted instance does not retract its announcement",
    () => {
      const p = make();
      const s = accept(p, E1);
      p.endInstance(s, 1);
      assert.equal(p.mark, E1);
      assert.equal(p.nextCandidate(2), E1);
      p.withdraw(path(E1));
      assert.equal(p.nextCandidate(3), undefined);
      assert.equal(p.acceptedEpoch, undefined);
      const q = make();
      const qs = accept(q, E1);
      assert.equal(q.endInstance(forged(E1), 1), false);
      assert.equal(q.endInstance(qs, 1), true);
      assert.equal(q.endInstance(qs, 1), false);
    },
  ],
  [
    "I36 distinct track names per instance are capped; unknown names keep no counters",
    () => {
      const p = make();
      const s = accept(p);
      const first = tracker(p, s, "t0");
      frame(first, 5n);
      for (let i = 1; i < 128; i++) tracker(p, s, "t" + i);
      assert.deepEqual(p.track(s, "t128", 120n), {
        kind: "unavailable_retryable",
        track: "t128",
        reason: "track_limit",
      });
      assert.equal(p.trackCount, 128);
      assert.deepEqual(p.trackFailure({ name: "never-listed" } as any, 2), { kind: "ignored" });
      assert.equal(p.trackCount, 128);
      assert.equal(first.current, true);
      assert.equal(tracker(p, s, "t0").mark?.group, 5n);
    },
  ],
  [
    "I37 budget exhaustion beside an accepted stream keeps playback and supersession facts",
    () => {
      const p = make(E1);
      const s = accept(p, E2);
      assert.equal(p.status.superseded, true);
      for (let i = 0; i < 11; i++) {
        const e = epoch(100 + i);
        p.announce(path(e));
        const c = must(p.subscribe(e, 10 + i));
        assert(c);
        p.rejectCandidate(c, 10 + i);
      }
      p.announce(path(epoch(200)));
      assert.equal(p.nextCandidate(30), undefined);
      const exhausted = {
        inviteNeeded: false,
        playback: "ready",
        superseded: true,
        probing: "idle",
        budgetExhausted: true,
        olderStreamOnly: false,
        candidatesIncomplete: false,
      };
      assert.deepEqual(p.status, exhausted);
      assert.deepEqual(p.states, ["superseded_by_another_instance", "unavailable_retryable"]);
      assert.equal(p.authenticated(s, "bridge.tracks", 31), "refreshed");
      assert.equal(p.nextCandidate(32), undefined);
      assert.deepEqual(p.status, exhausted);
      assert.equal(p.acceptedEpoch, E2);
    },
  ],
  [
    "I38 older_stream_only only when no candidate at or above the mark remains",
    () => {
      const p = make();
      const s = accept(p, E2);
      p.announce(path(E1));
      p.announce(path(E3));
      p.endInstance(s, 1);
      assert.equal(p.status.olderStreamOnly, false);
      assert.equal(p.nextCandidate(2), E3);
      const s3 = must(p.subscribe(E3, 2));
      assert(s3);
      assert.equal(p.status.olderStreamOnly, false);
      assert.equal(p.status.probing, "probing");
      p.rejectCandidate(s3, 3);
      p.withdraw(path(E3));
      assert.equal(p.status.olderStreamOnly, false);
      p.withdraw(path(E2));
      assert.equal(p.status.olderStreamOnly, true);
      assert.deepEqual(p.states, ["older_stream_only"]);
    },
  ],
  [
    "I39 authenticated reports first acceptance, refresh and re-acceptance",
    () => {
      const p = make();
      const s = start(p, E1);
      assert.equal(p.authenticated(s, "video", 1), false);
      assert.equal(p.authenticated(s, "bridge.tracks", 1), "accepted");
      assert.equal(p.authenticated(s, "bridge.tracks", 2), "refreshed");
      p.endInstance(s, 2);
      assert.equal(p.authenticated(s, "bridge.tracks", 3), false);
      const again = must(p.subscribe(E1, 4));
      assert(again);
      assert.equal(p.authenticated(again, "bridge.tracks", 5), "accepted");
    },
  ],
  [
    "I40 resume below the accepted epoch stays superseded without waiting for a manifest",
    () => {
      const p = make(E1);
      accept(p, FAST);
      p.resumePublishing(E2);
      assert.equal(p.status.superseded, true);
      assert.deepEqual(p.states, ["superseded_by_another_instance"]);
      const q = make(E1);
      accept(q, E2);
      q.resumePublishing(E3);
      assert.equal(q.status.superseded, false);
      assert.deepEqual(q.states, ["ready"]);
    },
  ],
  [
    "I41 timeout backoff is capped at sixty seconds",
    () => {
      const p = make();
      p.announce(path(E1));
      let now = 0;
      for (const wait of [3000, 6000, 12000, 24000, 48000, 60000, 60000, 60000]) {
        assert(p.subscribe(E1, now));
        const deadline = now + 1500;
        p.tick(deadline);
        assert.equal(p.nextCandidate(deadline + wait - 1), undefined);
        assert.equal(p.nextCandidate(deadline + wait), E1);
        now = deadline + wait;
      }
    },
  ],
  [
    "I42 authentication failure reported after the deadline still bars sixty seconds",
    () => {
      const p = make();
      const s = start(p, E1);
      p.tick(1500);
      assert.equal(p.rejectCandidate(s, 1600), true);
      assert.equal(p.nextCandidate(4500), undefined);
      assert.equal(p.nextCandidate(61599), undefined);
      assert.equal(p.nextCandidate(61600), E1);
      assert.equal(p.rejectCandidate(forged(E2), 61601), false);
    },
  ],
  [
    "I43 announce distinguishes invalid from full and frees retracted records unclocked",
    () => {
      const p = make();
      for (let i = 0; i < 256; i++) assert.equal(p.announce(path(epoch(1000 + i))), "ok");
      assert.equal(p.announce(path(E1)), "full");
      assert.equal(p.announce("alice/call"), "invalid");
      for (let i = 0; i < 256; i++) p.withdraw(path(epoch(1000 + i)));
      assert.equal(p.announce(path(E1)), "ok");
      assert.equal(p.nextCandidate(0), E1);
    },
  ],
  [
    "I44 malformed epoch never authenticates",
    () => {
      const p = make();
      assert.equal(p.authenticated(undefined as any, "bridge.tracks", 0), false);
      assert.equal(p.authenticated(forged("nonsense"), "bridge.tracks", 0), false);
      assert.equal(p.acceptedEpoch, undefined);
      assert.equal(p.status.playback, "none");
    },
  ],
  [
    "I45 exhausted track resubscription reports when it may retry",
    () => {
      const p = make();
      const s = accept(p);
      for (let i = 0; i < 6; i++) failN(p, s, "audio", 1, 2 + i);
      assert.deepEqual(p.trackFailure(tracker(p, s, "audio"), 8), {
        kind: "unavailable_retryable",
        track: "audio",
        retryAt: 60002,
      });
      const h = p.retryTrack(s, "audio", 60002);
      assert(h instanceof TrackHandle);
      assert.equal(p.trackFailure(h, 60002).kind, "resubscribe");
    },
  ],
  [
    "I46 manifest at exactly 1500 ms after subscription is late",
    () => {
      const p = make();
      const s = start(p, E1);
      assert.equal(p.authenticated(s, "bridge.tracks", 1500), false);
      assert.equal(p.mark, undefined);
      const q = make();
      assert(q.authenticated(start(q, E1), "bridge.tracks", 1499));
    },
  ],
  [
    "G17 start pruned by the window stays refused",
    () => {
      const g = new GroupTracker(120n);
      frame(g, 100n);
      frame(g, 300n);
      assert.equal(g.remembered, 1);
      assert.equal(frame(g, 100n), "too_old");
      assert.equal(frame(g, 180n), "deliver");
      assert.equal(frame(g, 100n), "too_old");
    },
  ],
  // ---- C1 diff check 2026-11-25 (reviews/2026-11-25-c1-diff-check.md), scratch S1–S6 as rows.
  // Red against d4333b2: spikes/complete/logs/c1-callback-red.log.
  [
    "C01 (S1 fresh lookup) a retired session cannot register a track or deliver through the current one",
    () => {
      const p = make();
      const s1 = accept(p, E1, 0);
      const a = tracker(p, s1, "audio", 0n);
      assert.equal(frame(a, 100n), "deliver");
      assert.equal(frame(a, 100n), "duplicate");
      const s2 = accept(p, E2, 2);
      assert.deepEqual(p.track(s1, "audio", 0n), { kind: "stale", track: "audio" });
      const cur = tracker(p, s2, "audio", 0n);
      assert.equal(frame(cur, 10n), "deliver");
      assert.deepEqual(cur.mark, { group: 10n, index: 0 });
    },
  ],
  [
    "C02 (S1 cached) a handle cached before retirement returns stale and moves nothing",
    () => {
      const p = make();
      const s1 = accept(p, E1, 0);
      const a = tracker(p, s1, "audio", 0n);
      assert.equal(frame(a, 100n), "deliver");
      // Same-epoch retirement: the cached handle goes stale, the marks stay with the name.
      const s1b = bounce(p, s1, E1, 2);
      assert.equal(frame(a, 100n, 1), "stale");
      const b = tracker(p, s1b, "audio", 0n);
      assert.equal(frame(b, 100n), "duplicate");
      assert.equal(frame(b, 100n, 1), "deliver");
      // Greater-epoch retirement.
      const s2 = accept(p, E2, 10);
      assert.equal(frame(b, 200n), "stale");
      assert.equal(a.current, false);
      assert.equal(b.current, false);
      assert.equal(frame(tracker(p, s2, "audio", 0n), 10n), "deliver");
    },
  ],
  [
    "C03 (S2 pre-acceptance) an expired attempt's close or late manifest cannot act on its replacement",
    () => {
      const p = make();
      p.announce(path(E1));
      const first = must(p.subscribe(E1, 0));
      p.tick(1500);
      const second = must(p.subscribe(E1, 4500));
      assert(second);
      assert.notEqual(second, first);
      assert.equal(p.probeEnded(first, 4501), false);
      assert.equal(p.authenticated(first, "bridge.tracks", 4501), false);
      assert.equal(p.status.probing, "probing");
      assert.equal(p.authenticated(second, "bridge.tracks", 4502), "accepted");
    },
  ],
  [
    "C04 (S2 post-acceptance) a retired session's close and callbacks cannot touch the replacement",
    () => {
      const p = make();
      const s1 = accept(p, E1, 0);
      const h1 = tracker(p, s1, "audio");
      frame(h1, 20n);
      assert(p.endInstance(s1, 2));
      const s2 = must(p.subscribe(E1, 3));
      assert.equal(p.authenticated(s2, "bridge.tracks", 4), "accepted");
      assert.equal(p.endInstance(s1, 5), false);
      assert.equal(p.authenticated(s1, "bridge.tracks", 6), false);
      assert.deepEqual(p.trackFailure(h1, 7), { kind: "ignored" });
      assert.equal(p.acceptedEpoch, E1);
      assert.equal(frame(tracker(p, s2, "audio"), 20n), "duplicate");
    },
  ],
  [
    "C05 (S3a) a rejection with no issued probe behind it bars nothing",
    () => {
      const p = make();
      p.announce(path(E1));
      assert.equal(p.rejectCandidate(forged(E1), 1), false);
      const other = make();
      other.announce(path(E1));
      const foreign = must(other.subscribe(E1, 0));
      assert.equal(p.rejectCandidate(foreign, 1), false);
      assert.equal(p.nextCandidate(2), E1);
    },
  ],
  [
    "C06 (S3b) a late rejection of a withdrawn probe bars identically with or without a tick",
    () => {
      for (const ticked of [false, true]) {
        const p = make();
        p.announce(path(E1));
        const s = must(p.subscribe(E1, 0));
        p.withdraw(path(E1));
        if (ticked) p.tick(1500);
        assert.equal(p.rejectCandidate(s, 4500), true, `ticked ${ticked}`);
        p.announce(path(E1));
        assert.equal(p.nextCandidate(4501), undefined, `ticked ${ticked}`);
        assert.equal(p.nextCandidate(64499), undefined, `ticked ${ticked}`);
        assert.equal(p.nextCandidate(64500), E1, `ticked ${ticked}`);
      }
    },
  ],
  [
    "C07 (S3 lifetime) a report is honored for 60 s from its probe's start and never ends a replacement",
    () => {
      const p = make();
      p.announce(path(E1));
      const first = must(p.subscribe(E1, 0));
      p.tick(1500);
      const second = must(p.subscribe(E1, 4500));
      assert.equal(p.rejectCandidate(first, 4501), true);
      assert.equal(p.status.probing, "probing");
      assert.equal(p.authenticated(second, "bridge.tracks", 4502), "accepted");
      const q = make();
      q.announce(path(E1));
      const late = must(q.subscribe(E1, 0));
      assert.equal(q.rejectCandidate(late, 60000), false);
      assert.equal(q.nextCandidate(60000), E1);
    },
  ],
  [
    "C08 (S4) rapid closes of the accepted epoch are paced and cannot lock out a greater epoch",
    () => {
      const p = make();
      p.announce(path(E1));
      for (let t = 0; t <= 22; t += 2) {
        if (p.nextCandidate(t) !== E1) continue;
        const s = must(p.subscribe(E1, t));
        assert.equal(p.authenticated(s, "bridge.tracks", t + 1), "accepted");
        assert(p.endInstance(s, t + 1));
      }
      assert.equal(p.attemptCount, 2);
      p.announce(path(E2));
      assert.equal(p.nextCandidate(24), E2);
      assert.equal(p.mark, E1);
    },
  ],
  [
    "C09 (S4) one honest reconnect is immediate; a session that lasted 10 s resets the pacing",
    () => {
      const p = make();
      const s1 = accept(p, E1, 0);
      assert(p.endInstance(s1, 1));
      assert.equal(p.nextCandidate(1), E1);
      const s2 = must(p.subscribe(E1, 2));
      assert.equal(p.authenticated(s2, "bridge.tracks", 3), "accepted");
      assert(p.endInstance(s2, 4));
      assert.equal(p.nextCandidate(3003), undefined);
      assert.equal(p.nextCandidate(3004), E1);
      const s3 = must(p.subscribe(E1, 3004));
      assert.equal(p.authenticated(s3, "bridge.tracks", 3005), "accepted");
      assert(p.endInstance(s3, 13005));
      assert.equal(p.nextCandidate(13005), E1);
    },
  ],
  [
    "C10 (S5) budget exhaustion is reported beside a live probe and playback",
    () => {
      const p = make();
      accept(p, E1, 0);
      for (let i = 0; i < 10; i++) {
        const e = epoch(0x100 + i);
        p.announce(path(e));
        const c = must(p.subscribe(e, 2 + i));
        assert(c);
        p.rejectCandidate(c, 2 + i);
      }
      p.announce(path(epoch(0x200)));
      assert(p.subscribe(epoch(0x200), 12));
      assert.equal(p.attemptCount, 12);
      assert.equal(p.status.probing, "probing");
      assert.equal(p.status.budgetExhausted, true);
      assert.deepEqual(p.states, ["ready", "unavailable_retryable"]);
    },
  ],
  [
    "C11 (S6) a full table of below-mark records admits an epoch at or above the mark",
    () => {
      const p = make();
      const s = accept(p, epoch(1000), 0);
      p.endInstance(s, 1);
      p.withdraw(path(epoch(1000)));
      p.tick(2);
      for (let i = 1; i <= 256; i++) p.announce(path(epoch(i)));
      assert.equal(p.announce(path(epoch(1001))), "ok");
      assert.equal(p.announce(path(epoch(1002))), "ok");
      assert.equal(p.status.olderStreamOnly, false);
      // E1 and E2 were active when evicted, so the view is incomplete (diff check 2, A9).
      assert.equal(p.status.candidatesIncomplete, true);
      assert.equal(p.nextCandidate(3), epoch(1002));
    },
  ],
  [
    "C12 (S6) an unadmitted announcement makes the view incomplete, so older-only is not claimed",
    () => {
      const p = make();
      const s = accept(p, epoch(1000), 0);
      p.endInstance(s, 1);
      p.withdraw(path(epoch(1000)));
      p.tick(2);
      for (let i = 1; i <= 256; i++) assert.equal(p.announce(path(epoch(i))), "ok");
      assert.equal(p.status.olderStreamOnly, true);
      // A below-mark offer cannot evict a below-mark record: refused, and the view is incomplete.
      assert.equal(p.announce(path(epoch(300))), "full");
      assert.equal(p.status.candidatesIncomplete, true);
      assert.equal(p.status.olderStreamOnly, false);
      // An admission is not reconciliation (diff check 2, A5): the view stays incomplete.
      p.withdraw(path(epoch(1)));
      assert.equal(p.announce(path(epoch(300))), "ok");
      assert.equal(p.status.candidatesIncomplete, true);
      assert.equal(p.status.olderStreamOnly, false);
      // The adapter reconciles the authoritative active set; it fits, so the view is complete.
      const active = [300];
      for (let i = 2; i <= 256; i++) active.push(i);
      assert.equal(p.reconcile(active.map((i) => path(epoch(i)))), "complete");
      assert.equal(p.status.candidatesIncomplete, false);
      assert.equal(p.status.olderStreamOnly, true);
      assert.deepEqual(p.states, ["older_stream_only"]);
    },
  ],
  // ---- C1 diff check 2, 2026-11-25 (reviews/2026-11-25-c1-diff-check-2.md), A2–A10 as rows.
  // Red against 3cbd279: spikes/complete/logs/c1-round3-red.log.
  [
    "D01 (A2) a track handle retires on terminal failure; replay state and a clocked retry remain",
    () => {
      const p = make();
      const s = accept(p, E1, 0);
      const mirror = { m: 1 };
      const h = tracker(p, s, "audio", 0n, mirror);
      assert.equal(frame(h, 20n), "deliver");
      assert.equal(p.trackFailure(h, 2).kind, "resubscribe");
      // failure -> queued frame -> duplicate failure, all on the retired handle
      assert.equal(h.current, false);
      assert.equal(frame(h, 21n), "stale");
      assert.deepEqual(p.trackFailure(h, 3), { kind: "ignored" });
      // the replacement owns the same mirror and mark
      const r = tracker(p, s, "audio", 0n);
      assert.equal(r.mirror, mirror);
      assert.deepEqual(r.mark, { group: 20n, index: 0 });
      assert.equal(frame(r, 21n), "deliver");
      // five more distinct failed subscriptions spend the six slots; the seventh is exhausted
      assert.equal(p.trackFailure(r, 4).kind, "resubscribe");
      failN(p, s, "audio", 4, 5, 0n);
      const last = tracker(p, s, "audio", 0n);
      assert.deepEqual(p.trackFailure(last, 6), {
        kind: "unavailable_retryable",
        track: "audio",
        retryAt: 60002,
      });
      assert.equal(last.current, false);
      assert.equal((p.track(s, "audio", 0n) as any).reason, "retry_wait");
      assert.equal((p.retryTrack(s, "audio", 60001) as any).reason, "retry_wait");
      const back = p.retryTrack(s, "audio", 60002);
      assert(back instanceof TrackHandle);
      assert.equal(back.mirror, mirror);
      assert.equal(frame(back, 21n), "duplicate");
      assert.deepEqual(p.retryTrack(s, "never", 60003), { kind: "stale", track: "never" });
    },
  ],
  [
    "D02 (A3) one rejection per probe; a repeat never extends the bar",
    () => {
      const p = make();
      p.announce(path(E1));
      const s = must(p.subscribe(E1, 0));
      assert.equal(p.rejectCandidate(s, 1), true);
      assert.equal(p.rejectCandidate(s, 59999), false);
      assert.equal(p.nextCandidate(60000), undefined);
      assert.equal(p.nextCandidate(60001), E1);
    },
  ],
  [
    "D03 (A4) a newer same-epoch acceptance clears an earlier attempt's bar and fences its report",
    () => {
      for (const order of ["report-then-accept", "accept-then-report"]) {
        const p = make();
        p.announce(path(E1));
        const a = must(p.subscribe(E1, 0));
        p.tick(1500);
        const b = must(p.subscribe(E1, 4500));
        if (order === "report-then-accept") {
          assert.equal(p.rejectCandidate(a, 4501), true, order);
          assert.equal(p.authenticated(b, "bridge.tracks", 4502), "accepted", order);
        } else {
          assert.equal(p.authenticated(b, "bridge.tracks", 4502), "accepted", order);
          assert.equal(p.rejectCandidate(a, 4503), false, order);
        }
        assert(p.endInstance(b, 4504));
        assert.equal(p.rejectCandidate(a, 4505), false, order);
        assert.equal(p.nextCandidate(4505), E1, order);
      }
    },
  ],
  [
    "D04 (A5) after overflow an unrelated admission does not make the view complete",
    () => {
      const p = make();
      const s = accept(p, epoch(1000), 0);
      p.endInstance(s, 1);
      p.withdraw(path(epoch(1000)));
      p.tick(2);
      for (let i = 1001; i <= 1256; i++) assert.equal(p.announce(path(epoch(i))), "ok");
      assert.equal(p.announce(path(epoch(2000))), "full");
      for (let i = 1001; i <= 1256; i++) p.withdraw(path(epoch(i)));
      assert.equal(p.announce(path(E1)), "ok");
      assert.equal(p.status.candidatesIncomplete, true);
      assert.equal(p.status.olderStreamOnly, false);
      assert.equal(p.reconcile([path(E1), path(epoch(2000))]), "complete");
      assert.equal(p.status.olderStreamOnly, false);
      assert.equal(p.nextCandidate(3), epoch(2000));
    },
  ],
  [
    "D05 (A9) evicting an active record makes the view incomplete",
    () => {
      const p = make();
      const s = accept(p, epoch(1000), 0);
      p.endInstance(s, 1);
      p.withdraw(path(epoch(1000)));
      p.tick(2);
      for (let i = 1; i <= 256; i++) p.announce(path(epoch(i)));
      assert.equal(p.announce(path(epoch(1001))), "ok");
      for (let i = 2; i <= 256; i++) p.withdraw(path(epoch(i)));
      p.withdraw(path(epoch(1001)));
      assert.equal(p.status.candidatesIncomplete, true);
      assert.equal(p.status.olderStreamOnly, false);
      assert.equal(p.reconcile([path(E1)]), "complete");
      assert.equal(p.status.olderStreamOnly, true);
    },
  ],
  [
    "D06 reconcile: empty set completes, an overflowing set stays incomplete, bad input changes nothing",
    () => {
      const p = make();
      p.announce(path(E1));
      assert.equal(p.reconcile([]), "complete");
      assert.equal(p.nextCandidate(0), undefined);
      const big: string[] = [];
      for (let i = 1; i <= 300; i++) big.push(path(epoch(i)));
      assert.equal(p.reconcile(big), "incomplete");
      assert.equal(p.status.candidatesIncomplete, true);
      assert.equal(p.candidateCount, 256);
      // the greatest epochs are the ones kept
      assert.equal(p.nextCandidate(1), epoch(300));
      const before = JSON.stringify(p.inspect());
      assert.throws(() => p.reconcile(undefined as any), TypeError);
      assert.throws(() => p.reconcile(42 as any), TypeError);
      assert.equal(JSON.stringify(p.inspect()), before);
      assert.equal(p.reconcile(["bob/x/y", 7 as any, path(epoch(300))]), "complete");
    },
  ],
  [
    "D07 (A10) subscribe issues nothing without an eligible epoch, and never displaces a live probe",
    () => {
      const p = make();
      p.announce(path(E1));
      const a = must(p.subscribe(E1, 0));
      for (const bad of [undefined, null, 7, "", E2, E1.toUpperCase()])
        assert.equal(p.subscribe(bad as any, 1), false);
      assert.equal(p.attemptCount, 1);
      assert.equal(p.authenticated(a, "bridge.tracks", 2), "accepted");
      const q = make();
      assert.equal(q.subscribe(undefined as any, 0), false);
      assert.equal(q.subscribe(E1, 0), false);
      assert.equal(q.attemptCount, 0);
    },
  ],
  [
    "D08 (A10 audit) malformed, wrong-type and foreign arguments change no state on any method",
    () => {
      const p = make(E1);
      const s = accept(p, E2, 0);
      const h = tracker(p, s, "audio", 0n);
      frame(h, 5n);
      p.announce(path(E3));
      const other = make();
      const foreign = accept(other, E2, 0);
      const snap = () => JSON.stringify({ i: p.inspect(), st: p.status, m: p.mark, a: p.acceptedEpoch, n: p.attemptCount }, (_k, v) => (typeof v === "bigint" ? `${v}n` : v));
      const before = snap();
      const junk: any[] = [undefined, null, 0, NaN, "x", {}, [], E2, { epoch: E2 }, foreign, Symbol.iterator];
      const ok = (f: () => unknown) => {
        try {
          f();
        } catch (e) {
          assert(e instanceof TypeError || e instanceof RangeError, String(e));
        }
        assert.equal(snap(), before);
      };
      for (const j of junk) {
        ok(() => p.announce(j));
        ok(() => p.withdraw(j));
        ok(() => p.subscribe(j, 1));
        ok(() => p.authenticated(j, "bridge.tracks", 1));
        ok(() => p.authenticated(s, j, 1));
        ok(() => p.probeEnded(j, 1));
        ok(() => p.rejectCandidate(j, 1));
        ok(() => p.endInstance(j, 1));
        ok(() => p.trackFailure(j, 1));
        ok(() => p.track(j, "audio", 0n));
        // any string is a valid track name, so only non-strings are junk in that position
        if (typeof j !== "string") ok(() => p.track(s, j, 0n));
        ok(() => p.track(s, "audio", j));
        ok(() => p.retryTrack(j, "audio", 1));
        ok(() => p.retryTrack(s, j, 1));
        if (j !== E2) ok(() => p.resumePublishing(j)); // E2 is a valid, new epoch
        // [] is a valid (empty) active set; everything else here is not a set of paths
        if (!Array.isArray(j)) ok(() => p.reconcile(j));
        if (typeof j !== "number" || !Number.isFinite(j)) {
          ok(() => p.tick(j));
          ok(() => p.nextCandidate(j));
          ok(() => p.endInstance(s, j));
          ok(() => p.authenticated(s, "bridge.tracks", j));
          ok(() => p.trackFailure(h, j));
        }
      }
      ok(() => h.frame({ group: -1n, index: 0, authenticated: true }));
      ok(() => h.frame({ group: 1n, index: 1.5, authenticated: true }));
    },
  ],
  [
    "D09 (A6) a session of exactly 10 s resets the rapid streak to zero",
    () => {
      const p = make();
      const s1 = accept(p, E1, 0);
      assert(p.endInstance(s1, 1));
      const s2 = must(p.subscribe(E1, 2));
      assert.equal(p.authenticated(s2, "bridge.tracks", 2), "accepted");
      assert(p.endInstance(s2, 10002));
      assert.equal(p.nextCandidate(10002), E1);
      const s3 = must(p.subscribe(E1, 10002));
      assert.equal(p.authenticated(s3, "bridge.tracks", 10003), "accepted");
      assert(p.endInstance(s3, 10004));
      assert.equal(p.nextCandidate(10004), E1);
      // and the streak builds again from there
      const s4 = must(p.subscribe(E1, 10004));
      assert.equal(p.authenticated(s4, "bridge.tracks", 10005), "accepted");
      assert(p.endInstance(s4, 10006));
      assert.equal(p.nextCandidate(13005), undefined);
      assert.equal(p.nextCandidate(13006), E1);
    },
  ],
  [
    "E01 (randomized seed 1 step 285) tick is idempotent: an expiring withdrawn probe is purged in that tick",
    () => {
      const p = make();
      p.announce(path(E1));
      must(p.subscribe(E1, 0));
      p.withdraw(path(E1));
      p.tick(100000); // deadline at 1500, backoff to 4500, both long past
      const once = JSON.stringify(p.inspect());
      p.tick(100000);
      assert.equal(JSON.stringify(p.inspect()), once);
      assert.equal(p.candidateCount, 0);
    },
  ],
];
for (const [name, run] of rows) test(name, run);
