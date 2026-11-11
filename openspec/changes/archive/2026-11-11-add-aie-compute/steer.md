# steer add-aie-compute

**When.** 2026-11-07
**Depth.** explicit

## Decided
- Spike aie-npu-path: spike now (user). Later: go.
- Path: host sidecar RPC on dummy-mjolnir (user)
- Principal: Mjolnir VM being is the offerer; sidecar is plumbing (user)
- Grants: signed keyspace offers + guild inject as `member(ks, pk)` in this DAG (user)

## Skipped
- Easy client (OpenAI-compat vs XRT/IRON HTTP) — decided at
  `add-aie-guest-offer` named activate 2026-11-11: native
  `POST {aie_url}/v1/execute` + `mj compute` (not chat-completions)
- Laptop-only vs also prod server — `[AUTO]` 2026-11-11 stay-on-pin
  steer: Off without `/dev/accel`; Framework5070 is the NPU host;
  a host without the device omits `aie_url` (prod Vultr included)
- Multiplex vs exclusive NPU as a product — `[AUTO]` 2026-11-11
  stay-on-pin steer: exclusive occupancy stays (IRON Lab flock);
  not a product multiplex in v1

## Feeds change
ADD `aie-compute` as overlay sidecar + VM principal + keyspace claims + guild inject. No new Biscuit crypto. Spike finding is go; sidecar act still waits on this architecture advise accept.

## Consult 2026-11-11 (fable-5.2)
Caution. Sidecar-vs-VFIO stands. Pins taken into this change:
BEAM admits / sidecar enforces; operator allowlist of offering VMs;
leaf sequence + tombstone floor; v1 job = catalog design id;
try-lock then revalidate under deadline; holder is consumer VM with
member-signed delegation; locators as a map; audience is mint-root
fp. Whole-offer incarnation revocation is accepted for v1.

## Advise 2026-11-11 pass 2 (astra-arch-review)

Send-back. Pins taken into this change:
R5 — dedicated `/run/mjolnir/aie-admit.sock` (0660 root:`mjolnir-aie`),
not operator.sock; sidecar cannot use VM/snapshot routes; restart
does not widen access. Owned by `add-aie-host-sidecar`.
R6 — BEAM owns pending table; `pending_id` binds verified frame and
enqueue time; at-most-one dispatch; lost-reply retry; restart
invalidates; retries do not reset queue age. Shared by
`add-aie-host-sidecar` and `add-aie-guest-offer`.

## Advise 2026-11-11 pass 3 (astra-arch-review)

Send-back R6a. Pin: occupancy `attempt_id` at try-lock; live admit
on that attempt may load; BEAM `dispatched` is historical status;
abandon (deadline, lock release, cancel, restart) makes retry
status-only; fresh enqueue after abandon revalidates policy.
