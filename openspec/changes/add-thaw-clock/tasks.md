# Tasks

- [ ] While the restored VM is paused, set KVM clock to host time if the hypervisor API allows it
- [ ] If that write is unavailable, step guest wall time from the agent after `vm.resume` and before reachability
- [ ] Do not step `CLOCK_MONOTONIC`
- [ ] A failed clock step fails thaw the same way a failed entropy reseed does: no PTY, ticket, or gateway
- [ ] Test: a guest whose snapshot clock is hours behind reports host time before publish
