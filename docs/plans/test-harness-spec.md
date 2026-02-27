# Mjolnir Test Harness Specification

## Framework: Plain ExUnit (not Gherkin)

**Rationale**: Elixir's Gherkin libraries (`white_bread`, `cabbage`) are unmaintained since 2020-2021. ExUnit's `describe/test` blocks with good naming achieve the same readability. The Elixir community consensus (Phoenix, Ecto, Livebook, Nerves) is plain ExUnit.

`StreamData` is recommended as a future supplement for property-based testing of Protocol encode/decode roundtrips and IP allocation collision properties.

## Test Taxonomy — Three Layers

### Layer 1: Unit Tests (no infrastructure, run on macOS)

**Command**: `mix test`
**Tag**: none (default, always run)
**`async: true`** where possible

| File | Module | Tests | What it covers |
|------|--------|-------|----------------|
| `vsock/protocol_test.exs` | `ProtocolTest` | 40+ | Wire format encode/decode, all message builders, parse_iroh_ready, multi-frame |
| `network_test.exs` | `NetworkTest` | 12 | IP allocation range, .0/.255 avoidance, MAC generation, tap naming |
| `event_bus_test.exs` | `EventBusTest` | 9 | Subscribe/publish/unsubscribe, :all wildcard, multi-subscriber |
| `cloud_hypervisor/config_test.exs` | `ConfigTest` | 13 | Payload structure, boot_args root=myfs virtiofs, memory MiB→bytes, CID, fs_config |
| `vm_unit_test.exs` | `VMUnitTest` | 8 | CID generation bounds, determinism, struct defaults |
| `ticket_test.exs` | `TicketTest` | 7 | z32 encoding, nil handling, alphabet validation |
| `cleanup_test.exs` | `CleanupTest` | 1 | sweep/0 safety |
| `api/router_test.exs` | `RouterTest` | 8 | Health, CRUD 404s, auth bypass, scope enforcement |

### Layer 2: Integration Tests (need KVM + root)

**Command**: `mix test --include integration`
**Tag**: `@moduletag :integration`
**`async: false`** (VMs are expensive)

| File | Module | Tests | What it covers |
|------|--------|-------|----------------|
| `vm_test.exs` | `VMTest` | 14 | Spawn, exec, stop, resource cleanup, networking |
| `cloud_hypervisor_integration_test.exs` | `CHIntegrationTest` | 6 | CH-specific boot, root mount rw, unique CIDs, concurrent VMs, boot_time |
| `snapshot_test.exs` | `SnapshotTest` | 5 | Snapshot create, list, restore with state, delete |
| `vm_iroh_test.exs` | `VMIrohTest` | ~5 | Iroh enable/disable, ticket generation |

### Layer 3: End-to-End Tests (future, full API stack)

**Command**: `mix test --include e2e`
**Tag**: `@tag :e2e`

Full HTTP API lifecycle, WebSocket PTY, dormant VM wake-on-message.

## Running Tests

```bash
# Fast feedback (200ms, no infrastructure)
mix test

# With real VMs (on server with KVM)
mix test --include integration

# Including external network tests
mix test --include integration --include network

# Full suite
mix test --include integration --include e2e
```

## Test Infrastructure

### VMCase (test/support/vm_case.ex)
CaseTemplate that cleans up orphan VMs after each test via `on_exit`.

### ExUnit Tags
- `:integration` — needs KVM, root, BTRFS
- `:cloud_hypervisor` — CH-specific tests
- `:snapshot` — BTRFS snapshot tests
- `:network` — external connectivity tests
- `:slow` — multi-VM concurrent tests

### Future: Mock Hypervisor
The `Mjolnir.Hypervisor` behaviour (8 callbacks) is a clean seam for a mock implementation that would unlock testing the VM GenServer state machine, Router happy paths, and dormant restore flow without KVM. This is the highest-leverage testing investment (~4-6 hours).

## Implementation Priority

1. ✅ Protocol unit tests (pure functions, zero deps)
2. ✅ Network + Ticket + EventBus unit tests
3. ✅ CH Config unit tests (boot_args, CID, payload structure)
4. ✅ VM unit tests (CID generation, struct defaults)
5. ✅ Snapshot integration tests
6. ✅ Concurrent VM integration tests
7. ⬜ DormantRegistry unit tests
8. ⬜ Mock Hypervisor (enables testing VM GenServer without KVM)
9. ⬜ Expanded Router tests with mock hypervisor
10. ⬜ E2E API lifecycle tests
