# API Transport Security

This guide covers Mjolnir's HTTP API authentication, authorization, and secure transport patterns.

## Architecture Overview

```
┌─────────────┐
│   Client    │
│ (your Mac)  │
└──────┬──────┘
       │
       │ SSH tunnel (encrypted)
       │ ssh root@server "curl http://localhost:4000/..."
       │
       ▼
   ┌────────────────────────────────┐
   │  Server (Mjolnir @ 45.76...)   │
   │                                 │
   │  ┌──────────────────────┐       │
   │  │ Mjolnir HTTP API     │       │
   │  │ localhost:4000       │       │
   │  │ (no TLS)             │       │
   │  │ ├─ JWT auth (remote) │       │
   │  │ └─ localhost bypass  │       │
   │  └──────────────────────┘       │
   │           │                     │
   │           ▼                     │
   │  ┌──────────────────────┐       │
   │  │ Mjolnir VM Mgmt      │       │
   │  │ (spawn, exec, stop)  │       │
   │  └──────────────────────┘       │
   └────────────────────────────────┘
```

The API is **HTTP-only, localhost-bound**. All remote access must use SSH tunneling. This design ensures:
- No TLS overhead for localhost calls
- Impossible to accidentally expose API to internet
- SSH key infrastructure provides transport security
- Simpler auth (JWT optional if using SSH)

## Authentication Methods

### 1. JWT Bearer Token (Remote Access)

For clients connecting via SSH tunnel or from untrusted networks, use JWT:

```bash
# Get a token (production: use OIDC issuer)
TOKEN=$(curl -X POST https://auth.worldtree.io/token \
  -d "client_id=mjolnir&client_secret=$SECRET" \
  | jq -r .access_token)

# Use token via SSH tunnel
ssh root@server "curl -H 'Authorization: Bearer $TOKEN' \
  http://localhost:4000/api/vms" | jq .
```

**Token format**: JWT (JSON Web Token)
- **Issuer**: Configurable via `MJOLNIR_AUTH_ISSUER` environment variable
- **Verification**: `lib/mjolnir/auth/token.ex` validates signature and `sub` (subject/user ID)
- **Scopes**: Token claims include `scope` field (currently unused; all authenticated users get full access)

**Justfile integration**:
```bash
# Automatic JWT injection (if $MJOLNIR_TOKEN env var set)
just host=user@server vm-spawn
# Internally: ssh user@server "curl -H 'Authorization: Bearer $MJOLNIR_TOKEN' ..."
```

### 2. Localhost Bypass

If `auth.bypass_localhost: true` is configured, any request from 127.0.0.1 or ::1 is auto-authenticated as `user_id="localhost"` with full scopes:

```bash
# No token needed — curl directly on server
ssh root@server
# Inside server:
curl http://localhost:4000/api/vms | jq .
```

**Default**: `bypass_localhost: false` (requires JWT)

**Configure** in `config/config.exs`:
```elixir
config :mjolnir, :auth, bypass_localhost: true  # ONLY for trusted localhost SSH
```

**Security note**: Localhost bypass is safe if:
- SSH server uses key auth (no password login)
- SSH access is restricted to trusted users
- SSH tunnels are not forwarded (`ssh -N`, no shell)

### 3. Health Endpoint (No Auth)

The `/api/health` endpoint skips authentication entirely:
```bash
curl http://localhost:4000/api/health
# Returns: {"status": "ok"}
```

Used for load balancers, monitoring, uptime checks. No secrets exposed.

## Authorization (What You Can Do)

Authentication (who are you) is separate from authorization (what can you do).

Each API endpoint enforces an action:
| Endpoint | Action | Requires Scope |
|----------|--------|----------------|
| `POST /api/vms` | `vms:spawn` | Spawn new VM |
| `GET /api/vms` | `vms:read` | List VMs |
| `GET /api/vms/<id>` | `vms:read` | Inspect VM |
| `POST /api/vms/<id>/exec` | `vms:exec` | Run command |
| `DELETE /api/vms/<id>` | `vms:stop` | Stop VM |
| `POST /api/vms/<id>/pty` | `pty:connect` | PTY access |
| `POST /api/vms/<id>/snapshot` | `snapshots:create` | Create snapshot |

**Ownership model**: When you spawn a VM with user_id="alice", the VM is owned by "alice". Only alice (or an admin) can execute commands in it.

**Policy enforcement**: `lib/mjolnir/policy/vm.ex` checks ownership before allowing action:
```elixir
def authorize(action, user, vm) do
  if vm.owner_id == user.id or user.is_admin do
    :ok
  else
    {:error, :forbidden}
  end
end
```

## SSH Tunneling (Production Recommended)

The Justfile automates SSH tunneling. Internally, commands like:

```bash
just host=root@45.76.77.97 vm-spawn
```

Execute:

```bash
ssh root@45.76.77.97 "curl -X POST http://localhost:4000/api/vms ..."
```

### How It Works

1. **Local jq constructs JSON safely**: Avoids shell quoting issues
   ```bash
   body=$(jq -n "{vcpus: 2, memory_mb: 1024}")
   echo "$body" | ssh host "curl -d @- http://localhost:4000/..."
   ```

2. **SSH provides transport encryption**: API calls are encrypted in transit (unlike raw HTTP)

3. **SSH key authentication**: No passwords; keypair-based auth to server

### Security Properties

✅ **Encrypted in transit**: SSH tunneling encrypts all API traffic
✅ **No API exposure**: API never leaves localhost
✅ **Key-based auth**: SSH keys are per-server, can be rotated
✅ **Audit trail**: SSH logs show which user ran which command

❌ **Limited to SSH keys**: If SSH key is compromised, attacker has full API access
❌ **No per-VM granularity**: SSH access = full Mjolnir access (unless JWT auth is layered)

## Tokens & Key Management

### JWT Token Lifecycle

```
1. Issue (at auth issuer)
   │
   ├─ User authenticates (OIDC, email, etc.)
   └─ Issuer signs JWT with private key
      
2. Use (in curl)
   │
   └─ Client includes token in Authorization header
      
3. Verify (at Mjolnir API)
   │
   └─ API verifies signature with issuer's public key
      └─ If valid, extract user_id and grant access
```

**Token expiry**: Not currently enforced (TODO: add exp claim validation)
**Token rotation**: Issue new token on each auth; old tokens still valid until exp

**Justfile token injection**:
```bash
# If $MJOLNIR_TOKEN is set, use it automatically
export MJOLNIR_TOKEN="eyJhbGc..."
just vm-spawn  # Injects token in Authorization header
```

### SSH Key Management

**Per-server**: Create unique SSH keys for each Mjolnir server
```bash
ssh-keygen -t ed25519 -f ~/.ssh/mjolnir_45.76.77.97 -C "mjolnir"
# Add public key to ~/.ssh/authorized_keys on server
ssh -i ~/.ssh/mjolnir_45.76.77.97 root@45.76.77.97
```

**Justfile config** (`.env` file):
```
MJOLNIR_HOST=root@45.76.77.97
```

Justfile uses `ssh` from your shell, so it respects `~/.ssh/config`:
```ssh-config
Host mjolnir-prod
    HostName 45.76.77.97
    User root
    IdentityFile ~/.ssh/mjolnir_45.76.77.97
```

## Request/Response Security

### Request Validation

All user input is validated before use:

```elixir
# base_image path traversal prevention
case Validation.validate_safe_name(base_image, "base_image") do
  {:ok, name} -> use name
  {:error, msg} -> return 400 Bad Request
end

# memory_mb integer bounds check
Validation.validate_integer(memory_mb, 512, 128, 32_768)
# min=128 MB, max=32 GB, default=512 MB
```

**Validated fields**:
- `base_image` — alphanumeric + underscore only, no path traversal
- `memory_mb` — integer in [128, 32768]
- `vcpus` — integer in [1, 8]
- `snapshot` — snapshot name validation
- Commands via vsock — length-limited (65KB max frame)

### Response Security

Responses never include sensitive data:
- No SSH private keys in response
- No Iroh private keys in response
- No API tokens in response
- Owner ID is included (for audit, not secret)

Example response:
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "owner_id": "alice@example.com",
  "state": "running",
  "web_url": "https://abc123xyz789.vm.worldtree.network",
  "ticket": "z32encodehnodeid...",
  "vcpus": 2,
  "memory_mb": 1024
}
```

## Common Patterns

### Spawn VM with Custom SSH Key

```bash
just vm-spawn  # Interactive prompt for SSH public key
# OR
just vm-spawn ssh_public_key='ssh-ed25519 AAAA...'
```

The public key is injected via vsock at boot time; guest agent writes it to `/root/.ssh/authorized_keys`.

### List VMs Owned by User

```bash
just vm-list | jq '.vms[] | select(.owner_id == "alice")'
```

### Monitor API Performance

```bash
# Enable request logging (default: on)
tail -f /var/log/mjolnir/api.log | grep -E "POST|GET|DELETE"
```

## Troubleshooting

### "401 Unauthorized"

**Cause**: Token missing, invalid, or expired
**Fix**:
```bash
# Check token is set
echo $MJOLNIR_TOKEN

# Verify token format (should decode to JSON)
jq -R 'split(".") | .[1] | @base64d | fromjson' <<< "$MJOLNIR_TOKEN"

# Issue new token from auth issuer
```

### "403 Forbidden"

**Cause**: Token is valid but user doesn't own the VM
**Fix**:
```bash
# Check VM owner
just vm-info <id> | jq .owner_id

# Only owner can execute
just vm-exec <id> "whoami"  # If not owner, fails
```

### "SSH: Connection refused"

**Cause**: SSH key not in authorized_keys, wrong host
**Fix**:
```bash
# Test SSH directly
ssh -i ~/.ssh/mjolnir_45.76.77.97 root@45.76.77.97
# If fails, check key is in server's ~/.ssh/authorized_keys
```

### "curl: (7) Failed to connect to localhost port 4000"

**Cause**: Mjolnir service not running on server
**Fix**:
```bash
ssh root@45.76.77.97
systemctl status mjolnir
systemctl restart mjolnir
```

## References

- `lib/mjolnir/api/auth.ex` — Auth plug implementation
- `lib/mjolnir/api/router.ex` — Endpoint definitions
- `lib/mjolnir/policy/` — Authorization policies
- [OWASP API Security](https://owasp.org/www-project-api-security/)
