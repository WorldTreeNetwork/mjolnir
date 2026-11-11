# Design

Implements ADR 0015. Does not reopen sidecar-vs-VFIO.

## Decision — Unit, user, bind

Dedicated OS user `mjolnir-aie`, group `mjolnir-aie`, not uid 0.
The process opens `/dev/accel/accel0`. It is a member of
`mjolnir-aie` so it can connect to `aie-admit.sock`. It SHALL
NOT be given `/run/mjolnir/operator.sock`. Install rides
`just deploy`. Bind is `:host_api_ip:7422` on `dummy-mjolnir`,
never `0.0.0.0`, never `lo`. Guest TCP is INPUT.

## Decision — Locator map

`configure_identity` locators become a map before `aie_url` is
added (`lib/mjolnir/vsock/protocol.ex` is positional today).
`blob_door_url` stays. `aie_url` is present only when the unit
is up and `/dev/accel/accel0` exists.

## Decision — Admit channel and pending table

BEAM listener `/run/mjolnir/aie-admit.sock`, mode `0660`,
owner root, group `mjolnir-aie`. Pipeline is not
`OperatorPipeline`. Enqueue consumes the client nonce, stores
the verified frame, returns `pending_id`. Admission names
`pending_id` and occupancy `attempt_id`. Load authority is a
live success on the current attempt (ADR 0015 Decision 4 R6a).
Cached `dispatched` after abandon is status only.

## Decision — Occupancy

Try-lock, then admit under a deadline, then load or release.
Each successful try-lock is a new `attempt_id`. Hold the IRON
Lab flock identity (`$XDG_RUNTIME_DIR/ironlab/occupancy.lock`,
same `occupancy.json` schema as `ironlab-device`) from
catalog-design load until the XRT worker is reaped and the
device is quiescent. The worker SHALL inherit the flock fd
(or the sidecar SHALL refuse after try-lock if a live worker
pid remains). occupancy.rs dead-pid steal without inherit
admits a second claim while an orphan lives. v1 job is a
host-catalog design id plus bounded input. No guest xclbin.
Leaf wall time kills the worker.

## Unverified hypotheses

- Spike: `aie-occupancy-lock` sidecar and ironlab share one flock through timeout, cancel, and restart — go
  (`docs/spikes/aie-occupancy-lock/finding.md`). Worker inherits the flock fd. Overlay RPC is not this evidence.
