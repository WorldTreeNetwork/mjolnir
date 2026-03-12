# RBAC Design for Mjolnir

## Current State

Mjolnir uses scope-based authorization with JWT claims. The `scope` claim is a
space-separated string of permissions checked per-endpoint via `require_scope/2`.

### Scope Inventory

| Scope | Endpoints | Description |
|-------|-----------|-------------|
| `vms:spawn` | POST /api/vms | Create new VMs |
| `vms:read` | GET /api/vms, GET /api/vms/:id, GET /api/dormant | List and inspect VMs |
| `vms:exec` | POST /api/vms/:id/exec, POST /api/vms/:id/message | Execute commands and send messages |
| `vms:stop` | DELETE /api/vms/:id | Stop/destroy VMs |
| `pty:connect` | GET /api/vms/:id/ticket, GET /api/vms/:id/await-pty | PTY/Iroh connection |
| `terminal:read` | GET /api/vms/:id/terminal/:name, GET /api/vms/:id/terminal | Read output, list sessions |
| `terminal:write` | POST /api/vms/:id/terminal/*, DELETE /api/vms/:id/terminal/:name | Open, send, close sessions |
| `snapshots:create` | POST /api/vms/:id/snapshot | Create snapshots |
| `snapshots:read` | GET /api/snapshots, GET /api/snapshots/:name | List and inspect snapshots |
| `snapshots:delete` | DELETE /api/snapshots/:name | Delete snapshots |

### Authorization Layers

1. **Authentication** (`Mjolnir.API.Auth`) — Verifies JWT or localhost bypass
2. **Scope check** (`require_scope/2`) — Ensures the token has the required scope
3. **Ownership policy** (`Mjolnir.Policy.VM`, `Mjolnir.Policy.Snapshot`) — Resource-level owner check

### Localhost Bypass

Connections from `127.0.0.1` / `::1` bypass JWT auth and receive all scopes + `user_id: "localhost"`.
The policy layer grants localhost full access to all resources regardless of ownership.

## Proposed: Role-Based Access Control

### Roles

| Role | Scopes | Use Case |
|------|--------|----------|
| `viewer` | `vms:read`, `snapshots:read`, `terminal:read` | Read-only monitoring |
| `operator` | All of `viewer` + `vms:spawn`, `vms:exec`, `vms:stop`, `terminal:write`, `pty:connect`, `snapshots:create` | Day-to-day VM operations |
| `admin` | All scopes + `snapshots:delete` + bypass ownership checks | Full system administration |

### Implementation Path

1. **Phase 1 (current)**: Scope strings in JWT claims, checked per-endpoint
2. **Phase 2**: Map roles → scope sets in `Mjolnir.Auth.Roles` module. Token contains `role` claim,
   expanded to scopes at auth time. Backward-compatible — existing scope-based tokens still work.
3. **Phase 3**: Resource-level permissions (share VMs with other users, team ownership).
   Extends `Policy.VM` with ACL checks beyond simple owner match.

### Token Structure (Phase 2)

```json
{
  "sub": "user-123",
  "role": "operator",
  "scope": "vms:spawn vms:read vms:exec vms:stop terminal:read terminal:write pty:connect snapshots:create snapshots:read"
}
```

The `scope` claim remains authoritative. The `role` claim is informational and used by
`Mjolnir.Auth.Roles.expand_role/1` to generate scope strings during token creation.

### Open Questions

- Should `admin` role bypass ownership entirely, or should there be a separate `sudo` scope?
- Do we need per-VM ACLs (share a VM with another user) or is ownership sufficient?
- Should terminal:write imply terminal:read, or keep them independent?
- How do we handle scope escalation (user gets a new role while an old token is active)?
