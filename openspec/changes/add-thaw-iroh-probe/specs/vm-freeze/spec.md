## ADDED Requirements

### Requirement: Thaw health includes Iroh reachability
A thawed VM SHALL NOT be reported healthy, and SHALL NOT be reachable (PTY, ticket, gateway), until an Iroh reachability probe succeeds. A successful guest-agent vsock ping SHALL NOT satisfy that probe. The probe SHALL run only after entropy reseed and the wall-clock step have succeeded.

#### Scenario: Dead Iroh stays unhealthy
- GIVEN a thawed VM whose guest agent answers vsock ping
- AND whose Iroh node is not reachable
- WHEN the operator reads health
- THEN the VM is unhealthy
- AND no connection ticket is issued

#### Scenario: Probe success publishes
- GIVEN a thawed VM whose Iroh reachability probe succeeds after reseed and clock step
- WHEN the operator asks for a ticket
- THEN a ticket is issued
- AND health reports the VM healthy
