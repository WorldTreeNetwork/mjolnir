---
spike_id: fence-channel
hypothesis_id: null
source_synthesis: null
run_at: 2026-11-01T16:51:52-08:00
time_spent_min: 20
verdict: go
version-pinned: null
---

# Spike: fence-channel ordering

## Claim Tested

The host can order commit with transfer on one authenticated channel that is not guest disk. A go finding has to show three cases: acceptance is durable before the guest write even when commit never returns; a lost acceptance response is not resent and is not reusable authority; transfer or revocation while a guest write stalls, or while the channel disconnects, still shares that boundary. The callback-bearing trait keeps one ordering boundary and resolves interrupted work. This finding does not select a transport or a storage engine.

## Minimal Test

`docs/spikes/fence-channel/spike.exs` is a single process that stands in for the host side of `HostFence.commit/3`. The guest write is a callback. The process writes a witness term and syncs it before invoking the callback, and it does not answer the caller until the callback returns. Transfer is another call on that same process, so it waits in the mailbox while the callback is inside `commit`. The caller passes an authenticated instance id. A forged guest-disk map is never read. The witness file is only how the test observes the record while `commit` is still blocked. It is not a chosen engine.

## Evidence

Command: `elixir docs/spikes/fence-channel/spike.exs`

```
CASE1 pass acceptance_visible_before_callback writes=0
CASE2 pass lost_response_not_reusable writes=1
CASE3 pass transfer_queued_during_stall owner=inst-a gen=1
CASE3 pass disconnect_keeps_acceptance transfer_then_revokes writes=2
ALL pass
```

Case 1: the witness already held mutation `m1` for `inst-a` while the callback was blocked and the caller had not been answered. The write count was still 0.

Case 2: the caller discarded that answer and called `commit` again for `m1`. The callback was not entered. The result was `{:error, :not_reusable}`. The write count stayed 1.

Case 3: a second callback stalled. A transfer to `inst-b` was submitted and had not run after 100ms. The owner was still `inst-a` at generation 1, and `m2` was already on the witness. The caller was then killed. The `m2` record remained, and the transfer was still waiting. After the callback was released, the transfer ran, generation became 2, and the old grant was rejected. A later `commit` of `m2` did not enter the callback.

A channel value that disagreed with the grant (`inst-forged` against `inst-a`) was rejected before any write. The forged disk map was not an input to the host.

## Verdict: go

The three required cases held in this model. `commit` records acceptance, then runs the guest write callback, and only then returns, on the same serialized turn as transfer. Interrupted work stays resolved on that record: a lost or killed caller does not replay the response, and a retry is not a second authority and does not run the write again. Transfer cannot pass the in-flight callback. Nothing here picks vsock, an HTTP route, or a storage engine.

No source synthesis was on disk, so none was updated.
