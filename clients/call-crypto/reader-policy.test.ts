import { test } from "node:test";
import assert from "node:assert/strict";
import { InstancePolicy, GroupTracker } from "./reader-policy.ts";
const epoch = (n: number) => `${n.toString(16).padStart(8, "0")}-0000-7000-8000-000000000000`;
const E1 = epoch(1),
  E2 = epoch(2),
  E3 = epoch(3),
  FAST = epoch(0xffffffff);
const scope = { profile: "moq-e2ee-01-wip", kid: 1, label: "alice", opaque: "A".repeat(22) };
const path = (e: string) => `alice/${scope.opaque}/${e}`;
const make = (own?: string) => new InstancePolicy(scope, own);
function start(p: any, e: string, now = 0) {
  p.announce(path(e));
  assert.equal(p.nextCandidate(now), e);
  assert(p.subscribe(e, now));
}
function accept(p: any, e = E1, now = 0) {
  start(p, e, now);
  assert(p.authenticated(e, "bridge.tracks", now + 1));
}
const frame = (g: any, group: bigint, index = 0, authenticated = true) =>
  g.frame({ group, index, authenticated });
// track() returns a GroupTracker, or a track-scoped refusal at the per-instance name cap.
function tracker(p: any, name: string, window = 120n, mirror?: unknown): GroupTracker {
  const t = p.track(name, window, mirror);
  assert(t instanceof GroupTracker, `track ${name} refused`);
  return t;
}
// The accepted broadcast ends and the relay announces the same epoch again (or an honest reconnect).
function bounce(p: any, e: string, now: number) {
  p.endInstance(e);
  p.announce(path(e));
  assert.equal(p.nextCandidate(now), e);
  assert(p.subscribe(e, now));
  assert(p.authenticated(e, "bridge.tracks", now + 1));
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
      start(p, E2);
      assert(p.rejectCandidate(E2, 1));
      assert.equal(p.mark, undefined);
      assert.equal(p.nextCandidate(2), E1);
      assert(p.subscribe(E1, 2));
      assert(p.authenticated(E1, "bridge.tracks", 3));
      assert.equal(p.mark, E1);
    },
  ],
  [
    "I04 re-served older instance does not roll back",
    () => {
      const p = make();
      accept(p, E2);
      p.announce(path(E1));
      assert.equal(p.nextCandidate(2), undefined);
      assert.equal(p.subscribe(E1, 2), false);
      assert.equal(p.authenticated(E1, "bridge.tracks", 3), false);
      p.endInstance(E2);
      p.withdraw(path(E2));
      assert.equal(p.subscribe(E1, 4), false);
      assert.equal(p.authenticated(E1, "bridge.tracks", 5), false);
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
      assert(p.subscribe(E3, 1520));
      assert(p.rejectCandidate(E3, 1521));
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
        start(p, e, i * 2);
        p.rejectCandidate(e, i * 2 + 1);
      }
      p.announce(path(FAST));
      assert.equal(p.nextCandidate(30), undefined);
      assert.equal(p.status.probing, "budget_exhausted");
      assert.deepEqual(p.states, ["unavailable_retryable"]);
      assert.equal(p.nextCandidate(60003), FAST);
    },
  ],
  [
    "I10 authentication bars candidate for sixty seconds",
    () => {
      const p = make();
      start(p, E1);
      p.rejectCandidate(E1, 1);
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
      accept(p, E2);
      p.announce(path(E1));
      p.endInstance(E2);
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
      start(p, E2);
      assert.equal(p.status.superseded, false);
      p.authenticated(E2, "bridge.tracks", 1);
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
      accept(p, FAST);
      p.announce(path(E2));
      assert.equal(p.nextCandidate(2), undefined);
      p.endInstance(FAST);
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
      accept(p, FAST);
      for (const e of [E2, E3]) {
        p.resumePublishing(e);
        assert.equal(p.authenticated(FAST, "bridge.tracks", 10), "refreshed");
        assert.equal(p.status.superseded, true);
      }
      assert.equal(p.mark, FAST);
    },
  ],
  [
    "I17 track failure keeps instance generation mark and mirror",
    () => {
      const p = make();
      accept(p);
      const g = tracker(p, "video");
      frame(g, 20n, 1);
      const mirror = g.mirror;
      const action = p.trackFailure(E1, "video", 2);
      assert.deepEqual(action, {
        kind: "resubscribe",
        epoch: E1,
        track: "video",
        preserveMark: true,
        preserveMirror: true,
      });
      assert.equal(p.acceptedEpoch, E1);
      assert.equal(p.mark, E1);
      assert.equal(tracker(p, "video"), g);
      assert.equal(g.mirror, mirror);
      assert.equal(g.mark?.index, 1);
    },
  ],
  [
    "I18 six resubscriptions then unavailable",
    () => {
      const p = make();
      accept(p);
      tracker(p, "audio");
      for (let i = 0; i < 6; i++)
        assert.equal(p.trackFailure(E1, "audio", i + 2).kind, "resubscribe");
      assert.equal(p.trackFailure(E1, "audio", 8).kind, "unavailable_retryable");
      assert.equal(p.acceptedEpoch, E1);
    },
  ],
  [
    "I19 resubscription budget recovers after rolling minute",
    () => {
      const p = make();
      accept(p);
      tracker(p, "audio");
      for (let i = 0; i < 6; i++) p.trackFailure(E1, "audio", 2);
      assert.equal(p.trackFailure(E1, "audio", 3).kind, "unavailable_retryable");
      assert.equal(p.trackFailure(E1, "audio", 60002).kind, "resubscribe");
    },
  ],
  [
    "I20 resubscription budget is per track",
    () => {
      const p = make();
      accept(p);
      tracker(p, "audio");
      tracker(p, "video", 0n);
      for (let i = 0; i < 6; i++) p.trackFailure(E1, "audio", 2);
      assert.equal(p.trackFailure(E1, "video", 3).kind, "resubscribe");
    },
  ],
  [
    "I21 only manifest accepts instance",
    () => {
      const p = make();
      start(p, E1);
      assert.equal(p.authenticated(E1, "video", 1), false);
      assert.equal(p.mark, undefined);
      assert(p.authenticated(E1, "bridge.tracks", 2));
    },
  ],
  [
    "I22 late frame after probe timeout cannot accept",
    () => {
      const p = make();
      start(p, E1);
      assert.equal(p.authenticated(E1, "bridge.tracks", 1501), false);
      assert.equal(p.mark, undefined);
    },
  ],
  [
    "I23 timeout starts at subscription not announcement",
    () => {
      const p = make();
      p.announce(path(E1));
      assert.equal(p.nextCandidate(0), E1);
      assert(p.subscribe(E1, 10000));
      assert(p.authenticated(E1, "bridge.tracks", 11499));
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
      accept(p);
      tracker(p, "audio");
      assert.equal(p.rejectCandidate(E1, 2), false);
      assert.equal(p.acceptedEpoch, E1);
      assert.equal(p.trackFailure(E1, "audio", 3).kind, "resubscribe");
    },
  ],
  [
    "I27 withdrawal reannouncement cannot clear refusal or backoff",
    () => {
      const p = make();
      start(p, E1);
      p.rejectCandidate(E1, 1);
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
      accept(p);
      start(p, E2, 5);
      p.authenticated(E2, "bridge.tracks", 6);
      tracker(p, "audio");
      assert.deepEqual(p.trackFailure(E1, "audio", 7), { kind: "ignored" });
      for (let i = 0; i < 6; i++) assert.equal(p.trackFailure(E2, "audio", 8).kind, "resubscribe");
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
      accept(p);
      const mirror = {};
      const g = tracker(p, "catalog", 0n, mirror);
      assert.equal(g.mirror, mirror);
      frame(g, 20n, 1);
      assert.equal(tracker(p, "catalog", 0n, {}), g);
      assert.equal(p.trackFailure(E1, "catalog", 2).kind, "resubscribe");
      assert.equal(tracker(p, "catalog", 0n, {}).mirror, mirror);
      assert.equal(frame(g, 20n, 2), "deliver");
      assert.deepEqual(g.mark, { group: 20n, index: 2 });
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
      accept(p);
      const a = tracker(p, "audio");
      frame(a, 20n);
      assert.equal(tracker(p, "video", 0n).mark, undefined);
      start(p, E2, 5);
      p.authenticated(E2, "bridge.tracks", 6);
      assert.notEqual(tracker(p, "audio"), a);
      assert.equal(tracker(p, "audio").mark, undefined);
      assert.equal(a.mark?.group, 20n);
    },
  ],
  [
    "G16 changing window keeps the first window and mark",
    () => {
      const p = make();
      accept(p);
      const a = tracker(p, "audio", 120n);
      frame(a, 200n);
      const again = p.track("audio", 0n);
      assert.equal(again, a);
      assert.equal(again.window, 120n);
      assert.equal(frame(a, 100n), "deliver");
      assert.deepEqual(a.mark, { group: 200n, index: 0 });
    },
  ],
  [
    "I31 same-epoch re-acceptance keeps group/frame marks and mirror (bounce then replay)",
    () => {
      const p = make();
      accept(p, E1);
      const mirror = {};
      const audio = tracker(p, "audio", 120n, mirror);
      for (let g = 0n; g <= 1000n; g += 20n) assert.equal(frame(audio, g), "deliver");
      assert.equal(frame(audio, 1000n), "duplicate");
      p.tick(10);
      bounce(p, E1, 20);
      assert.equal(p.mark, E1);
      const again = tracker(p, "audio", 120n);
      assert.equal(again, audio);
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
      accept(p, E1);
      tracker(p, "audio");
      for (let i = 0; i < 6; i++) assert.equal(p.trackFailure(E1, "audio", 2).kind, "resubscribe");
      assert.equal(p.trackFailure(E1, "audio", 3).kind, "unavailable_retryable");
      p.tick(4);
      bounce(p, E1, 5);
      assert.equal(p.trackFailure(E1, "audio", 7).kind, "unavailable_retryable");
    },
  ],
  [
    "I33 accepting a greater epoch releases the older epoch's trackers and budgets",
    () => {
      const p = make();
      accept(p, E1);
      const a = tracker(p, "audio");
      tracker(p, "video", 0n);
      frame(a, 20n);
      for (let i = 0; i < 6; i++) p.trackFailure(E1, "audio", 2);
      assert.equal(p.trackCount, 2);
      start(p, E2, 5);
      assert(p.authenticated(E2, "bridge.tracks", 6));
      assert.equal(p.trackCount, 0);
      assert.notEqual(tracker(p, "audio"), a);
      for (let i = 0; i < 6; i++) assert.equal(p.trackFailure(E2, "audio", 7).kind, "resubscribe");
    },
  ],
  [
    "I34 probe ended by the transport backs off like a timeout, never retracts",
    () => {
      // A misrouted endInstance on a live probe is not a retraction and does not end the probe.
      const q = make();
      q.announce(path(E1));
      start(q, E3, 0);
      q.endInstance(E3);
      assert.equal(q.nextCandidate(1), undefined);
      assert.equal(q.status.probing, "probing");
      assert.equal(q.endInstance(E3), false);
      q.tick(1500);
      assert.equal(q.nextCandidate(1500), E1);
      // probeEnded: backoff from the end, no bar, fall through to the real candidate.
      const p = make();
      p.announce(path(E1));
      start(p, E3, 0);
      assert(p.probeEnded(E3, 0));
      p.announce(path(E3));
      assert.equal(p.nextCandidate(1), E1);
      assert(p.subscribe(E1, 1));
      assert.equal(p.authenticated(E1, "bridge.tracks", 2), "accepted");
      assert.equal(p.nextCandidate(2999), undefined);
      assert.equal(p.nextCandidate(3000), E3);
      assert.equal(p.attemptCount, 2);
      assert.equal(p.probeEnded(E2, 3001), false);
    },
  ],
  [
    "I35 transport end of the accepted instance does not retract its announcement",
    () => {
      const p = make();
      accept(p, E1);
      p.endInstance(E1);
      assert.equal(p.mark, E1);
      assert.equal(p.nextCandidate(2), E1);
      p.withdraw(path(E1));
      assert.equal(p.nextCandidate(3), undefined);
      assert.equal(p.acceptedEpoch, undefined);
      const q = make();
      accept(q, E1);
      assert.equal(q.endInstance(E2), false);
      assert.equal(q.endInstance(E1), true);
      assert.equal(q.endInstance(E1), false);
    },
  ],
  [
    "I36 distinct track names per instance are capped; unknown names keep no counters",
    () => {
      const p = make();
      accept(p);
      const first = tracker(p, "t0");
      frame(first, 5n);
      for (let i = 1; i < 128; i++) tracker(p, "t" + i);
      assert.deepEqual(p.track("t128", 120n), {
        kind: "unavailable_retryable",
        track: "t128",
        reason: "track_limit",
      });
      assert.equal(p.trackCount, 128);
      assert.deepEqual(p.trackFailure(E1, "never-listed", 2), { kind: "ignored" });
      assert.equal(p.trackCount, 128);
      assert.equal(tracker(p, "t0"), first);
      assert.equal(first.mark?.group, 5n);
    },
  ],
  [
    "I37 budget exhaustion beside an accepted stream keeps playback and supersession facts",
    () => {
      const p = make(E1);
      accept(p, E2);
      assert.equal(p.status.superseded, true);
      for (let i = 0; i < 11; i++) {
        const e = epoch(100 + i);
        p.announce(path(e));
        assert(p.subscribe(e, 10 + i));
        p.rejectCandidate(e, 10 + i);
      }
      p.announce(path(epoch(200)));
      assert.equal(p.nextCandidate(30), undefined);
      const exhausted = {
        inviteNeeded: false,
        playback: "ready",
        superseded: true,
        probing: "budget_exhausted",
        olderStreamOnly: false,
      };
      assert.deepEqual(p.status, exhausted);
      assert.deepEqual(p.states, ["superseded_by_another_instance", "unavailable_retryable"]);
      assert.equal(p.authenticated(E2, "bridge.tracks", 31), "refreshed");
      assert.equal(p.nextCandidate(32), undefined);
      assert.deepEqual(p.status, exhausted);
      assert.equal(p.acceptedEpoch, E2);
    },
  ],
  [
    "I38 older_stream_only only when no candidate at or above the mark remains",
    () => {
      const p = make();
      accept(p, E2);
      p.announce(path(E1));
      p.announce(path(E3));
      p.endInstance(E2);
      assert.equal(p.status.olderStreamOnly, false);
      assert.equal(p.nextCandidate(2), E3);
      assert(p.subscribe(E3, 2));
      assert.equal(p.status.olderStreamOnly, false);
      assert.equal(p.status.probing, "probing");
      p.rejectCandidate(E3, 3);
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
      start(p, E1);
      assert.equal(p.authenticated(E1, "video", 1), false);
      assert.equal(p.authenticated(E1, "bridge.tracks", 1), "accepted");
      assert.equal(p.authenticated(E1, "bridge.tracks", 2), "refreshed");
      p.endInstance(E1);
      assert.equal(p.authenticated(E1, "bridge.tracks", 3), false);
      assert(p.subscribe(E1, 4));
      assert.equal(p.authenticated(E1, "bridge.tracks", 5), "accepted");
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
      start(p, E1);
      p.tick(1500);
      assert.equal(p.rejectCandidate(E1, 1600), true);
      assert.equal(p.nextCandidate(4500), undefined);
      assert.equal(p.nextCandidate(61599), undefined);
      assert.equal(p.nextCandidate(61600), E1);
      assert.equal(p.rejectCandidate(E2, 61601), false);
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
      assert.equal(p.authenticated("nonsense", "bridge.tracks", 0), false);
      assert.equal(p.acceptedEpoch, undefined);
      assert.equal(p.status.playback, "none");
    },
  ],
  [
    "I45 exhausted track resubscription reports when it may retry",
    () => {
      const p = make();
      accept(p);
      tracker(p, "audio");
      for (let i = 0; i < 6; i++) p.trackFailure(E1, "audio", 2 + i);
      assert.deepEqual(p.trackFailure(E1, "audio", 8), {
        kind: "unavailable_retryable",
        track: "audio",
        retryAt: 60002,
      });
      assert.equal(p.trackFailure(E1, "audio", 60002).kind, "resubscribe");
    },
  ],
  [
    "I46 manifest at exactly 1500 ms after subscription is late",
    () => {
      const p = make();
      start(p, E1);
      assert.equal(p.authenticated(E1, "bridge.tracks", 1500), false);
      assert.equal(p.mark, undefined);
      const q = make();
      start(q, E1);
      assert(q.authenticated(E1, "bridge.tracks", 1499));
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
];
for (const [name, run] of rows) test(name, run);
