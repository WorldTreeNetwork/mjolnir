# Tasks

- [x] Define the Iroh reachability probe (what success is, and the timeout)
  - Success is guest `get_iroh_status` with `ready: true` and a non-empty node id within 5000 ms (`Mjolnir.Thaw.Publish.classify_iroh/1`). That is the guest endpoint being up, not a second host dialing it over QUIC.
- [x] Thaw publishes PTY, ticket, and gateway only after that probe succeeds
  - When `enable_iroh` is false there is no endpoint. Reseed and the wall step still gate; the probe is skipped. Default is Iroh on.
- [x] Status/doctor report the VM unhealthy while the probe is failing
  - `Publish.health/1` is `:unhealthy`. A failed probe fails the thaw (`abandon_thaw`), so doctor has no running VM to bless. A later rot of a published VM is still `Health.IrohConnection`.
- [x] A vsock ping success does not flip that report to healthy
- [x] Test the unhealthy report without a live Iroh peer, and the healthy report when the probe is stubbed ok
