# Design

Implements the guest slice of ADR 0015. Does not reopen
sidecar-vs-VFIO or guild inject.

## Decision — `mj compute`

`mj compute share` publishes (or points at) the current signed
offer for this VM being. `mj compute run` mints a holder-bound
execute token for the caller and POSTs the catalog job to
`aie_url`. Spawn does not mint capacity. The host OS user of the
sidecar is not the offer principal.

## Decision — HTTP on the locator

v1 execute is `POST {aie_url}/v1/execute` (`http://10.200.0.1:7422`
when on). The sidecar already binds that path. Body names a
host-catalog `design_id` and bounded input bytes. A live retry
repeats the same `pending_id`. Not OpenAI `/v1/chat/completions`.
Overlay origin is not the sole audience; audience is this host's
mint-root fingerprint.

## Decision — Guest retry

The guest (or `mj`) keeps `pending_id` from enqueue. While the
current occupancy `attempt_id` is live, retry of that
`pending_id` is the same job. After abandon, restart, cancel, or
max queue age, the client MUST obtain a fresh nonce and enqueue
again. This node owns that client contract; the sidecar already
owns the table.

## Unverified hypotheses

None. Occupancy lock is go (`docs/spikes/aie-occupancy-lock/finding.md`).
Overlay RPC is go (`docs/spikes/aie-npu-path/finding.md`).
