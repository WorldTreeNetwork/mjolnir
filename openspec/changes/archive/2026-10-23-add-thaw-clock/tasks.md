# Tasks

- [x] While the restored VM is paused, set KVM clock to host time if the hypervisor API allows it
  - The REST API this repo speaks has no clock-set endpoint (CH `docs/api.md`). Nothing to call while paused. The agent path is the one that shipped.
- [x] If that write is unavailable, step guest wall time from the agent after `vm.resume` and before reachability
- [x] Do not step `CLOCK_MONOTONIC`
- [x] A failed clock step fails thaw the same way a failed entropy reseed does: no PTY, ticket, or gateway
- [x] Test: a guest whose snapshot clock is hours behind reports host time before publish
