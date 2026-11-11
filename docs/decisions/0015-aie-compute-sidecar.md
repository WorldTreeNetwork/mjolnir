# ADR 0015 — AIE compute as a host sidecar

**Status:** Accepted (2026-11-11)
**Change:** [`add-aie-compute`](../../openspec/changes/add-aie-compute/proposal.md) (inflight)
**Living spec:** `openspec/specs/aie-compute/spec.md` (not folded yet)
**Spike:** [`aie-npu-path`](../spikes/aie-npu-path/finding.md) — overlay RPC go; the guest has no `/dev/accel`
**Advise:** [`reviews/2026-11-11-advise.md`](../../openspec/changes/add-aie-compute/reviews/2026-11-11-advise.md) — accepted (astra-arch-review)
**Full argument:** [`openspec/changes/add-aie-compute/design.md`](../../openspec/changes/add-aie-compute/design.md)

## One screen

1. Sidecar on `:host_api_ip:7422`, INPUT, locator `aie_url`.
2. No guest accel/DRM node. No VFIO for this capability.
3. Offer principal = VM IdentiKey; mint issuer = this host's
   production Biscuit root on that being's instruction.
4. Canonical resource `{owner_fp, offer_id}` plus leaf-hash
   incarnation on the execute right. Execute = redeem-shaped
   request proof, then injected holder; guild = injected member
   from an admission-time lookup.
5. Capacity = signed keyspace claim; admission-time policy;
   replacement mints a new incarnation.
6. Occupancy flock from load until worker quiescence.
7. Off = no device or unit down; omit locator.

## Built vs remaining

Built: this ADR and the contract (design, spec delta, advise accept).
Nothing in the sidecar exists yet. Incarnation is Blake3 of the canonical
signed offer leaf on the execute right; membership is revalidated at
admission and enqueue evidence is unused.

Remaining, as named children (blocked until activated):

- `add-aie-host-sidecar` — unit, bind, INPUT, `just deploy` install, occupancy lock. Spike `aie-occupancy-lock` is **unverified** and owned here.
- `add-aie-guest-offer` — `mj` verb and HTTP route shape.
- `add-aie-keyspace-claims` — SecretStore offer leaf.
- `add-guild-compute-holder` — `member(ks, pk)` inject.
- Fold the living spec after the implement nodes land.

## Scenarios

Every Requirement in the change spec has named Scenarios for implement nodes to close.

- **Guest never receives the NPU device:** Guest has no accel node
- **Overlay locator when the sidecar is up:** Locator present on an NPU host; Locator absent without a device
- **VM being is the offer principal:** Host process is not the offerer; Missing being fails closed
- **Execute is a holder-checked Biscuit:** Holder mismatch is refused; Mint without a guild still works; Stolen token without possession proof is refused; Replay and rebound job are refused; Untrusted issuer is refused
- **Guild-scoped offers inject membership:** Guild member runs; Stranger is fail-closed; Removed member and withdrawn offer fail at admission; Member key mismatch is refused; Removal before TTL expiry fails at admission; Removal after the freshness bound fails at admission; Membership lookup failure fails closed
- **Capacity is a signed keyspace claim:** Spawn does not mint capacity; Unsigned offer is refused; Cross-keyspace id collision does not share rights; Unrelated VM in a signed leaf is refused; Replacement invalidates the old incarnation; Personal-to-guild replacement rejects the old token; Tombstone recreation does not revive an old grant
- **Sidecar serializes NPU occupancy:** Second run does not clobber; Timeout does not overlap a new load; Restart with a live worker fails closed
