# steer add-aie-compute

**When.** 2026-11-07
**Depth.** explicit

## Decided
- Spike aie-npu-path: spike now (user). Later: go.
- Path: host sidecar RPC on dummy-mjolnir (user)
- Principal: Mjolnir VM being is the offerer; sidecar is plumbing (user)
- Grants: signed keyspace offers + guild inject as `member(ks, pk)` in this DAG (user)

## Skipped
- Easy client (OpenAI-compat vs XRT/IRON HTTP) — still open; `add-aie-guest-offer`
- Laptop-only vs also prod server — still open; Off is fail-closed without a device
- Multiplex vs exclusive NPU as a product — occupancy serialize is pinned from IRON Lab flock (safety), not from this menu

## Feeds change
ADD `aie-compute` as overlay sidecar + VM principal + keyspace claims + guild inject. No new Biscuit crypto. Spike finding is go; sidecar act still waits on this architecture advise accept.
