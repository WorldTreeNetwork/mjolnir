# Tasks

- [ ] Define the Iroh reachability probe (what success is, and the timeout)
- [ ] Thaw publishes PTY, ticket, and gateway only after that probe succeeds
- [ ] Status/doctor report the VM unhealthy while the probe is failing
- [ ] A vsock ping success does not flip that report to healthy
- [ ] Test the unhealthy report without a live Iroh peer, and the healthy report when the probe is stubbed ok
