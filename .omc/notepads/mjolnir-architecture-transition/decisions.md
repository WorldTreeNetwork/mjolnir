# Architectural Decisions - Vsock Refactoring

## Decision 1: Two-tier Connection Strategy

**Context**: Need to support both boot-time configuration and runtime command execution.

**Decision**: Use ephemeral synchronous connections for boot, persistent async connection for runtime.

**Rationale**:
- Boot configuration happens once, in sequence, with the VM GenServer blocked
- Synchronous helpers (`vsock_request/3`) are simpler and safer for boot sequence
- Runtime commands need async, persistent connection for efficiency
- The `Vsock.Connection` GenServer already supports persistent mode with buffering

**Trade-offs**:
- Slightly more complex than using persistent connection everywhere
- But avoids early connection issues during boot when guest agent might not be ready
- Keeps boot error handling simple and sequential

## Decision 2: Start Persistent Connection After All Configuration

**Context**: When should we start the persistent `Vsock.Connection`?

**Decision**: Last step of `do_boot/1`, after all configure_* calls complete.

**Rationale**:
- Configuration functions use synchronous helpers that don't need persistent connection
- Ensures guest agent is fully ready before persistent connection
- Simplifies error handling - if config fails, no connection to clean up
- Connection is ready immediately when VM enters :running state

**Alternatives Considered**:
- Start connection early and use it for configuration: Rejected because configuration is sequential and synchronous anyway
- Start on first exec: Rejected because it would add latency to first command

## Decision 3: Connection Cleanup in terminate/2

**Context**: How to clean up the persistent vsock connection?

**Decision**: Stop it first in `cleanup/1` before other resources.

**Rationale**:
- Connection needs to be stopped before socket files are deleted
- GenServer.stop is clean and waits for termination
- Placed first in cleanup to prevent races with socket deletion

## Decision 4: Default Timeout Strategy

**Context**: Different operations have different timeout needs.

**Decision**:
- `vsock_connect/2`: No default, always explicit (varies 2s-5s)
- `vsock_request/3`: Default 10s, explicit override for iroh_status (5s)

**Rationale**:
- Ping needs fast timeout (2s) to avoid blocking boot
- Most config operations need moderate timeout (10s)
- Iroh status polling needs shorter timeout (5s) for responsiveness
- Explicit timeouts prevent "one size fits all" problems
