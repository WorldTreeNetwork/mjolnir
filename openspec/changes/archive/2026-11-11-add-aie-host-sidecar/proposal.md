# add-aie-host-sidecar

> **ACTIVE BUILD**

Bead `mjolnir-io3b.5`. **Rigor:** change. Group: weave (with
`add-aie-guest-offer` once that node is unblocked).
Activated 2026-11-11 by campaign grant on `mjolnir-io3b`
("activate"; not "and run"). Architecture
`add-aie-compute` / ADR 0015 accepted
(`reviews/2026-11-11-advise-4.md`).

**Preparation (2026-11-11):** still valid against ADR 0015.
Upstream: spike `aie-npu-path` go (`60d9d85`); architecture
accept pass-4. Authority: campaign grant on `mjolnir-io3b`,
this dependency-ready node only. Occupancy hyp
`aie-occupancy-lock` is go (`docs/spikes/aie-occupancy-lock/finding.md`).
`add-aie-guest-offer` stays PENDING (blocked on this node).

## Why

The architecture pinned overlay AIE: a host sidecar on
`:host_api_ip:7422`, INPUT, locator `aie_url`, dedicated
non-root user, BEAM admit on `aie-admit.sock`, occupancy
try-lock. None of that unit, listener, or flock exists yet.
Blob-door is the install pattern (`just deploy`, dummy-mjolnir,
never `0.0.0.0`).

## What

- Systemd unit, user `mjolnir-aie` in group `mjolnir-aie`,
  access to `/dev/accel/accel0`, not root, not `operator.sock`.
- Bind `10.200.0.1:7422` (config `:aie_compute_port`), INPUT,
  fail-closed without dummy-mjolnir.
- Locator map in `configure_identity`; inject `aie_url` when
  the unit is up and `/dev/accel/accel0` exists.
- BEAM admit listener `/run/mjolnir/aie-admit.sock` (`0660`
  root:`mjolnir-aie`), pending table, `pending_id` +
  `attempt_id` load authority per ADR 0015 Decision 4/6.
- IRON occupancy flock; catalog design ids only; wall-time kill.
- Catalog row in `docs/guide/host-sidecars.md` becomes built.

## Impact

- Capabilities: MODIFIED `blob-store` (locator map); implements
  inflight `aie-compute` (not folded)
- ADRs: 0015 (already accepted; this node materializes it)
- Living spec: `openspec/specs/aie-compute/spec.md` on fold of
  the architecture node after implement landings

## User journey & surfaces

No new UI because guests already read `/etc/mjolnir/vm.json`
and reach overlay HTTP (blob-door). `add-aie-guest-offer`
picks the `mj` verb and execute path shape.

- **Working** — guest `curl` of `aie_url` reaches the sidecar;
  one catalog job loads after BEAM admit; second job waits on
  the flock; Off omits `aie_url`.
- **Empty** — no unit, no `aie_url`, blob-door locators unchanged.
- **Failed** — sidecar is root, uses `operator.sock`, binds
  `0.0.0.0`, or loads a guest xclbin.
- **Off** — no `/dev/accel/accel0` or unit stopped.

## Out of scope

- `mj` verb / HTTP route shape — `add-aie-guest-offer`
- SecretStore offer leaf — `add-aie-keyspace-claims`
- `member(ks, pk)` inject — `add-guild-compute-holder`
- Fold of architecture `aie-compute` before this landing
- VFIO / virtio-accel / `mjolnir-03x`
