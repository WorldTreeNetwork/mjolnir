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
      assert.equal(p.acceptedEpoch, E2);
    },
  ],
  [
    "I05 plaintext wrong label and wrong opaque refused",
    () => {
      const p = make();
      for (const v of ["alice/call", `bob/${scope.opaque}/${E1}`, `alice/${"B".repeat(22)}/${E1}`])
        assert.equal(p.announce(v), false);
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
    "I08 probing failure keeps accepted playback",
    () => {
      const p = make();
      accept(p);
      start(p, E2, 10);
      p.tick(1510);
      assert.equal(p.acceptedEpoch, E1);
      assert.equal(p.mark, E1);
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
      assert.equal(p.state, "unavailable_retryable");
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
        assert.equal(p.announce(path(e)), false);
    },
  ],
  [
    "I12 ended selected instance keeps mark",
    () => {
      const p = make();
      accept(p, E2);
      p.announce(path(E1));
      p.endInstance(E2);
      assert.equal(p.mark, E2);
      assert.equal(p.nextCandidate(2), undefined);
      assert.equal(p.state, "older_stream_only");
    },
  ],
  [
    "I13 second device supersedes publisher only after authentication",
    () => {
      const p = make(E1);
      start(p, E2);
      assert.notEqual(p.state, "superseded_by_another_instance");
      p.authenticated(E2, "bridge.tracks", 1);
      assert.equal(p.state, "superseded_by_another_instance");
      p.resumePublishing(E3);
      assert.equal(p.publishingEpoch, E3);
      assert.equal(p.mark, E2);
    },
  ],
  [
    "I14 reload new page loses credential and mark",
    () => {
      const p = make();
      accept(p, E2);
      const blank = new InstancePolicy();
      assert.equal(blank.state, "invite_needed");
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
      p.endInstance(FAST);
      assert.equal(p.nextCandidate(2), undefined);
      assert.equal(p.state, "older_stream_only");
      assert.equal(make().mark, undefined);
    },
  ],
  [
    "I16 recorded greater manifest supersedes after each resume",
    () => {
      const p = make(E1);
      accept(p, FAST);
      for (const e of [E2, E3]) {
        p.resumePublishing(e);
        assert(p.authenticated(FAST, "bridge.tracks", 10));
        assert.equal(p.state, "superseded_by_another_instance");
      }
      assert.equal(p.mark, FAST);
    },
  ],
  [
    "I17 track failure keeps instance generation mark and mirror",
    () => {
      const p = make();
      accept(p);
      const g = p.track("video", 120n);
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
      assert.equal(p.track("video", 120n), g);
      assert.equal(g.mirror, mirror);
      assert.equal(g.mark?.index, 1);
    },
  ],
  [
    "I18 six resubscriptions then unavailable",
    () => {
      const p = make();
      accept(p);
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
      assert(p.announce(path(E1)));
      assert.equal(p.scope?.label, "alice");
    },
  ],
  [
    "I26 accepted failure is not candidate rejection",
    () => {
      const p = make();
      accept(p);
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
      for (let i = 1; i <= 256; i++) assert(p.announce(path(epoch(i))));
      assert.equal(p.announce(path(epoch(257))), false);
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
    "G10 mirror identity survives equal group continuation",
    () => {
      const mirror = {};
      const g = new GroupTracker(0n, mirror);
      frame(g, 20n, 1);
      const mark = g.mark;
      assert.equal(g.mirror, mirror);
      frame(g, 20n, 2);
      assert.deepEqual(mark, { group: 20n, index: 1 });
      assert.equal(g.mirror, mirror);
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
      const a = p.track("audio", 120n);
      frame(a, 20n);
      assert.equal(p.track("video", 0n).mark, undefined);
      start(p, E2, 5);
      p.authenticated(E2, "bridge.tracks", 6);
      assert.notEqual(p.track("audio", 120n), a);
      assert.equal(p.track("audio", 120n).mark, undefined);
      assert.equal(a.mark?.group, 20n);
    },
  ],
  [
    "G16 changing window cannot reset existing mark",
    () => {
      const p = make();
      accept(p);
      p.track("audio", 120n);
      assert.throws(() => p.track("audio", 0n), TypeError);
    },
  ],
];
for (const [name, run] of rows) test(name, run);
