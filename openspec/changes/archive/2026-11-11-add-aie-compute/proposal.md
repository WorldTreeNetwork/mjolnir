# add-aie-compute

> **ACTIVE BUILD**

Bead `mjolnir-io3b.2`. **Rigor:** architecture. Group: human-gate.
Activated by the campaign grant on `mjolnir-io3b` ("activate", 2026-11-07).
Spike `aie-npu-path` is `go`
([`docs/spikes/aie-npu-path/finding.md`](../../../docs/spikes/aie-npu-path/finding.md)).

**Preparation (2026-11-11, R5/R6/R6a):** revised. Upstream:
`reviews/2026-11-11-advise-2.md` and `reviews/2026-11-11-advise-3.md`
send-backs. Authority: campaign grant on `mjolnir-io3b`
(architecture contract only). Outcome: dedicated `aie-admit.sock`,
BEAM `pending_id`, occupancy `attempt_id` load authority (cached
dispatched is status-only). Historical Astra accept does not cover
this revision. Fresh advise owed. Occupancy hyp still unverified
(gates sidecar act).

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
  incarnation (Blake3 of the signed leaf). The BEAM admits on
  `/run/mjolnir/aie-admit.sock` (distinct from the root-only
  operator socket); the sidecar enforces. The BEAM owns pending
  request state; `pending_id` binds the verified frame for
  at-most-one dispatch. Guild-scoped offers inject `member(ks, pk)`
  plus a member-signed delegation to the consumer VM holder.
  Token crypto does not change (identikey-capability D5).
- Capacity is a signed SecretStore keyspace record on an
  operator allowlist of offering VMs. Spawn does not mint a
  capacity asset. Sequence + tombstone floor; whole-offer
  revocation for v1.
- Occupancy: try-lock, revalidate under deadline, then load.
  v1 job is a host-catalog design id plus bounded input.
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
  treats the host process as the IdentiKey principal, lets the
  sidecar admit without the BEAM, grants the sidecar the operator
  socket, or loads a guest xclbin.
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
- OpenAI-compatible vs native IRON client — pinned at
  `add-aie-guest-offer` activate: native `POST /v1/execute` +
  `mj compute` (not chat-completions)
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
Fable 5.2 consult 2026-11-11: caution. Pins in this revision.
`Fresh advise after preparation` is owed; Astra's 2026-11-11 accept
does not cover this contract. Act remaining: amend ADR 0015
one-screen. Not the sidecar.
