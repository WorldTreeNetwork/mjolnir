# ADR 0015 — AIE compute as a host sidecar

**Status:** Accepted (2026-11-11); **amended 2026-11-11** after fable-5.2 consult and Astra send-backs (R5/R6/R6a) — fresh advise owed
**Change:** [`add-aie-compute`](../../openspec/changes/add-aie-compute/proposal.md) (inflight)
**Living spec:** `openspec/specs/aie-compute/spec.md` (not folded yet)
**Spike:** [`aie-npu-path`](../spikes/aie-npu-path/finding.md) — overlay RPC go; the guest has no `/dev/accel`
**Advise:** [`reviews/2026-11-11-advise.md`](../../openspec/changes/add-aie-compute/reviews/2026-11-11-advise.md) — accepted (historical); pass-2 and pass-3 send-back R5/R6/R6a; this amendment does not inherit those verdicts
**Consult:** [`fable-5.2-consult.md`](../../groups/add-aie-compute/results/fable-5.2-consult.md) — caution
**Full argument:** [`openspec/changes/add-aie-compute/design.md`](../../openspec/changes/add-aie-compute/design.md)

## One screen

1. Sidecar on `:host_api_ip:7422`, INPUT, locator `aie_url` in a
   locator map. Dedicated OS user, not root.
2. No guest accel/DRM node. No VFIO for this capability.
3. Offer principal = VM IdentiKey on an operator allowlist; mint
   issuer = this host's production Biscuit root.
4. BEAM admits on `/run/mjolnir/aie-admit.sock` (not
   operator.sock); sidecar enforces. BEAM pending table;
   `pending_id` binds the verified frame. Load needs a live
   admit on the current occupancy `attempt_id`; cached
   dispatched is status only. Redeem-shaped proof; audience is
   mint-root fp. Holder = consumer VM; guild = injected member
   plus member-signed delegation.
5. Canonical resource `{owner_fp, offer_id}` plus leaf-hash
   incarnation and increasing sequence. Tombstone is a floor.
   Whole-offer revocation for v1.
6. v1 job = host-catalog design id + bounded input. Occupancy:
   try-lock, revalidate under deadline, load until quiescence.
7. Off = no device or unit down; omit locator.

## Built vs remaining

Built: this ADR and the contract (design, spec delta). Sidecar unit,
admit socket, occupancy flock, offer leaf, guild inject, and guest
`mj compute` share/run plus `POST {aie_url}/v1/execute` live
`pending_id` retry are folded into living `aie-compute`. BEAM
admits; sidecar enforces. Incarnation is Blake3 of the canonical
signed offer leaf; sequence + tombstone floor; whole-offer
revocation for v1. Holder is the consumer VM. Membership is
revalidated after try-lock. The offer principal is the sharing
VM IdentiKey, not the sidecar process.

Remaining, as named children:

- Fold parent `add-aie-compute` after this landing.

Folded 2026-11-11: `add-aie-host-sidecar`, `add-aie-keyspace-claims`, `add-guild-compute-holder`, `add-aie-guest-offer`. Occupancy spike is go.

## Scenarios

Every Requirement in the change spec has named Scenarios for implement nodes to close.

- **Guest never receives the NPU device:** Guest has no accel node
- **Overlay locator when the sidecar is up:** Locator present on an NPU host; Locator absent without a device
- **VM being is the offer principal:** Host process is not the offerer; Missing being fails closed
- **Sidecar admits on a scoped BEAM channel:** Non-root sidecar can enqueue and admit; Sidecar identity cannot use operator VM routes; Listener restart does not widen access; Unrelated local user cannot admit
- **Execute is a holder-checked Biscuit:** Holder mismatch is refused; Mint without a guild still works; Stolen token without possession proof is refused; Replay and rebound job are refused; Untrusted issuer is refused; Sidecar without BEAM admit is refused; Stale queue is refused; Admission without enqueue is refused; Changed job or reference is refused; Concurrent duplicate admission dispatches once; Lost-admit-reply retry may load only on a live attempt; Lost reply then lock release cannot load after revocation; Late success after abandonment does not load; Duplicate successes start at most one load; Restart invalidates pending work; Expired or cancelled reference cannot be reused
- **Guild-scoped offers inject membership:** Guild member runs; Stranger is fail-closed; Removed member and withdrawn offer fail at admission; Member key mismatch is refused; Consumer VM holder with member delegation runs; Lookup is not performed while waiting on the flock; Removal before TTL expiry fails at admission; Removal after the freshness bound fails at admission; Membership lookup failure fails closed
- **Capacity is a signed keyspace claim:** Spawn does not mint capacity; Unsigned offer is refused; Cross-keyspace id collision does not share rights; Unrelated VM in a signed leaf is refused; Replacement invalidates the old incarnation; Personal-to-guild replacement rejects the old token; Tombstone recreation does not revive an old grant; Guest not on the allowlist cannot offer; Re-put of retired bytes is refused
- **Sidecar serializes NPU occupancy:** Second run does not clobber; Timeout does not overlap a new load; Restart with a live worker fails closed; Guest xclbin is refused; Wall time bound is enforced
