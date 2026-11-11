# add-aie-compute

> **ACTIVE BUILD**

Bead `mjolnir-io3b.2`. **Rigor:** architecture. Group: human-gate.
Activated by the campaign grant on `mjolnir-io3b` ("activate", 2026-11-07).
Spike `aie-npu-path` is `go`
([`docs/spikes/aie-npu-path/finding.md`](../../../docs/spikes/aie-npu-path/finding.md)).

## Why

The Framework5070 NPU (AMD Strix Halo / Krackan, `amdxdna`,
`/dev/accel/accel0`) already runs IRON Lab AIE kernels on the host.
Sharing that compute through a Mjolnir VM has no capability, no
overlay locator, no offer principal, and no IdentiKey grant. VFIO
is the GPU story in hardware-requirements §5; Cloud Hypervisor
config has no PCI devices. A guest that received `/dev/accel` would
need host KMD and would fight IRON occupancy. The product ask is
easy share, keyed by IdentiKey keyspaces and guilds.

## What

- ADR 0015: AIE compute is a host sidecar on `:host_api_ip`, not
  VFIO, not an OTP-only worker (`mjolnir-03x` stays out of this DAG).
- The Mjolnir VM's IdentiKey is the offer principal. The sidecar is
  plumbing, like virtiofsd.
- Guests never receive accel or DRM device nodes.
- Locator `aie_url` in `/etc/mjolnir/vm.json` when the sidecar is
  up. Absent when there is no NPU or the unit is off.
- Execute is a holder-checked Biscuit right bound to an offer
  incarnation (Blake3 of the signed leaf). Guild-scoped offers add
  a verifier-injected `member(ks, pk)` fact from an admission-time
  lookup. Token crypto does not change (identikey-capability D5).
- Capacity is a signed SecretStore keyspace record. Spawn does not
  mint a capacity asset. Replacement mints a new incarnation.
- Occupancy: the sidecar serializes NPU programs (IRON Lab flock).
  Two guests do not load two designs at once.
- Capability `aie-compute` (ADDED). Materialized by fold after the
  implement nodes land. This change writes the contract and the ADR.

## Impact

- Capabilities: ADDED `aie-compute`
- ADRs: 0015 (this change)
- Living spec: `openspec/specs/aie-compute/spec.md` on fold
- Host sidecars guide grows a catalog row after the sidecar node

## User journey & surfaces

No new UI because share and run already reach `mj` and the guest
locator. `add-aie-guest-offer` picks the HTTP routes and the `mj`
verb. This change decides who may run and where the bytes live.

- **Working (after implement nodes)** — owner shares from a VM on
  the NPU host; a guild member runs one IRON job through the locator;
  a stranger is fail-closed.
- **Empty** — `openspec/specs/aie-compute/` does not exist yet.
  Correct until fold.
- **Failed** — a later change VFIO-binds the NPU, injects
  `/dev/accel` into the guest, mints capacity inside `VM.spawn/1`,
  or treats the host process as the IdentiKey principal.
- **Off** — no `/dev/accel/accel0` (or the unit is stopped). No
  `aie_url`. Blob-door, Postgres, and Redis locators unchanged.

## Out of scope

- Host sidecar unit, bind, INPUT, install — `add-aie-host-sidecar`
  (`mjolnir-io3b.5`)
- Easy `mj` verb and HTTP route shape — `add-aie-guest-offer`
  (`mjolnir-io3b.6`)
- Signed offer records in SecretStore — `add-aie-keyspace-claims`
  (`mjolnir-io3b.7`)
- Guild membership inject implementation — `add-guild-compute-holder`
  (`mjolnir-io3b.4`)
- VFIO / virtio-accel
- OTP-only host worker (`mjolnir-03x`)
- OpenAI-compatible vs native IRON client (unmenued; guest-offer)
- Production Vultr host without an NPU
- Parakeet ASR encoder (IRON Lab operators, not this capability)
- Investor instruments / Registry ferry matching

## Preparation

Outcome: revised. Upstream `mjolnir-io3b.1` closed. Spike go at
`docs/spikes/aie-npu-path/finding.md` (commit `60d9d85`): guest
`Awrn8teovvzhNoRQDg3JLr` `POST http://10.200.0.1:7422/hello`, IRON
vector-add `Match: True`, guest had no `/dev/accel`. Steer 2026-11-07:
sidecar RPC, VM principal, keyspace offers + guild inject. Authority:
campaign grant on `mjolnir-io3b` ("activate"). This node only.
Fresh advise is owed before act. Act of this change is the ADR, not
the sidecar.
