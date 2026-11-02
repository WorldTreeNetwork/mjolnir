# Design

## What the host owes the trait

The guest opens a journal and asks the host. The host is the authority for three values the guest disk must not supply: journal identity, the current owner-instance handle, and a monotonic generation.

`classify` compares the guest's receipts to every admission the host still retains. A key the guest is missing, a digest that disagrees, or a row the host cannot decide is an incomplete classification. Adoption stops.

`identity` returns journal and instance. Generation rides on the grant. The host owns all three.

`begin_adoption` returns the grant the host already holds for that designated instance, pending or confirmed. It does not issue a second grant and it does not demote a confirmed grant. A retry, even after a fresh valid classification of the same history, returns that grant and does not bump the generation. Recovery is classify, then begin_adoption, then commit(Adopt), then confirm. `commit(Adopt)` validates and persists the supplied grant. It does not issue another one. `confirm` is idempotent and moves a pending grant to confirmed. Pending grants do not Lease or Admit. Another instance cannot confirm. An authenticated instance the host has not designated cannot elect itself by calling begin.

The accepting owner's coverage advances atomically on the classification id the host issued. Another holder of that same id is the same classification. A separately issued id, whose coverage the host did not advance, becomes stale. Other instances' classifications stay stale. A receipt's generation is compared with the generation stored on that retained admission. An earlier generation stays valid when it matches that admission. It is not compared with the current ownership grant. Generation zero is a legacy unfenced row, not host admission authority. Unknown rows during classification and foreign classifications are rejected.

Adopt needs a host-designated instance and a complete current classification. `begin_adoption` is what issues the grant. Lease and Admit need a confirmed grant, the matching journal and generation, and the exact mutation. A valid fresh Admit may introduce a key the host does not yet retain. Reconcile is a separate authorization: it may name a revoked grant to identify an existing key, and it does not create an admission. A revoked grant alone does not authorize the reconciler. An unknown key on Reconcile fails closed. Admit rejects a different digest for a key the host already retains. Classify rejects a receipt whose digest disagrees with that admission. Reconcile names scope and key only. It checks authorization and the existing key, and it leaves the retained digest unchanged. Effect-contract identifiers are policy-owned.

Acceptance and its ownership and generation binding are durable before the host invokes or releases the guest write, including when commit never returns. Begin, confirm, and transfer are durable before the host exposes their results. A crash after begin keeps the pending grant and does not reuse the generation. Restart reloads them. A lost reply does not resend. Uncertain recovery fails closed and does not reset the generation. Commit is not a reusable authorization token. Transfer or revocation while a guest write is stalled, or while the channel is disconnected, still shares that boundary.

`begin_adoption` for the same designated instance and the same history returns the same grant. A grant copied onto another instance does not elect that instance as owner.

`commit` checks the channel instance, the grant, the classification, and the exact mutation. It makes that acceptance durable before the guest write runs. Transfer and revocation share that boundary. If the guest write fails, the host keeps the admission. If contact is lost or the grant is revoked, the lease is gone before the next mutation. Rows already admitted stay recorded and are not sent again.

Transfer revokes the previous grant and issues a new instance handle. Restore and clone advance the generation and drop the previous grants.

A receipt names scope, key, digest, claim state, and generation. It carries no secret and no response body. It is not proof that an upstream effect ran exactly once.

An admitted effect is not permission to send.

## Fence channel

fence-channel is `go`. `docs/spikes/fence-channel/finding.md` (2026-11-01) showed acceptance recorded before the guest-write callback returns, a lost or killed caller that does not replay that answer or rerun the write, and transfer waiting on the same serialized turn while the callback stalls. The finding does not pick vsock, the existing API, another port, or a storage engine. The witness file in the spike is not the host store.
