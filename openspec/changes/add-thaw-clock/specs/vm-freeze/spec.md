## ADDED Requirements

### Requirement: Thaw steps wall time before reachability
A thaw SHALL make the guest wall clock agree with host time before the VM is reachable (PTY, ticket, gateway). The system SHALL NOT add the freeze duration to `CLOCK_MONOTONIC`. A clock step that fails SHALL fail the thaw and SHALL NOT publish the VM.

#### Scenario: Parked VM wakes on host time
- GIVEN a memory snapshot whose guest clock is more than an hour behind the host
- WHEN that snapshot is thawed
- THEN the guest wall clock matches host time before PTY, ticket, or gateway publish
- AND `CLOCK_MONOTONIC` has not jumped by the park duration

#### Scenario: Clock step failure stays unpublished
- GIVEN a thaw whose clock step fails
- WHEN the caller asks for a connection ticket
- THEN no ticket is issued
- AND the VM is not published on the gateway
