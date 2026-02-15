# Worker 1 - vsock refactoring (Tasks 1.1 + 1.2)

## Task 1.1: Extract vsock helpers
- [ ] Create `vsock_connect/1` helper - handles steps 1-3 (tcp connect, CONNECT, OK check)
- [ ] Create `vsock_request/3` helper - full request/response cycle
- [ ] Refactor `try_ping_agent/1` to use `vsock_connect/1`
- [ ] Refactor `configure_guest_network/2` to use `vsock_request/3`
- [ ] Refactor `configure_ssh/2` to use `vsock_request/3`
- [ ] Refactor `configure_identity/2` to use `vsock_request/3`
- [ ] Refactor `query_iroh_status/1` to use custom handling (extract fields)
- [ ] Verify compilation succeeds

## Task 1.2: Persistent vsock connection
- [ ] Add `:vsock_conn` field to VM state struct
- [ ] Start persistent `Vsock.Connection` at end of `do_boot/1`
- [ ] Store connection PID in state
- [ ] Modify `execute_command/2` to use persistent connection
- [ ] Verify compilation succeeds
- [ ] Run tests to ensure no behavior change

## Verification
- [ ] Run `mix compile` successfully
- [ ] Run `mix test` to verify no regressions
- [ ] Confirm line count reduction (~150 lines)
