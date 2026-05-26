# API Transport Security

This guide covers Mjolnir's HTTP API authentication, authorization, and secure transport patterns — including known limitations and security considerations.

## Architecture Overview

```
┌─────────────┐
│   Client    │
│ (your Mac)  │
└──────┬──────┘
       │
       │ SSH tunnel (encrypted transport)
       │ ssh root@server "curl http://localhost:4000/..."
       │
       ▼
   ┌────────────────────────────────────┐
   │  Server (Mjolnir @ 45.76...)       │
   │                                     │
   │  ┌──────────────────────────┐       │
   │  │ Mjolnir HTTP API         │       │
   │  │ localhost:4000           │       │
   │  │ (NO TLS — relies on SSH) │       │
   │  │ ├─ JWT auth (optional)   │       │
   │  │ └─ localhost bypass      │       │
   │  └──────────────────────────┘       │
   └────────────────────────────────────┘
```

The API is **HTTP-only, localhost-bound**. All remote access must use SSH tunneling. This design ensures the API cannot be accidentally exposed to the internet, but introduces security trade-offs (see "Security Limitations" below).

## Authentication Methods

### 1. JWT Bearer Token (Remote Access)

For clients connecting via SSH tunnel, use JWT:

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
- **Expiry**: Currently NOT enforced (⚠️ TODO: add `exp` claim validation)

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

⚠️ **SECURITY WARNING**: See "Security Limitations" section below.

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

### Security Properties & Limitations

✅ **Encrypted in transit**: SSH tunneling encrypts HTTP traffic at the transport layer
✅ **No API exposure**: API never leaves localhost on the server
✅ **Key-based auth**: SSH keys are per-server, can be rotated

⚠️ **SSH Key Compromise = Full API Access**: If an attacker obtains your SSH private key (`~/.ssh/mjolnir_45.76.77.97`), they have unrestricted access to **all API endpoints** and can manage **all VMs**.

⚠️ **No Application-Level Encryption**: The HTTP layer itself is unencrypted. If the SSH tunnel is compromised or misconfigured, JWT tokens are exposed as plaintext.

⚠️ **Tunnel Misconfiguration Risk**: SSH forwarding can expose the API if misused:
   ```bash
   # ❌ DANGEROUS: Remote forwarding exposes API on bastion
   ssh -R 8000:localhost:4000 bastion
   # Now bastion users can: curl http://localhost:8000/api/vms
   
   # ❌ DANGEROUS: Agent forwarding allows hijacking
   ssh -A bastion
   # Attacker on bastion can hijack SSH agent, access production
   ```

## Security Limitations

### Critical Limitation 1: SSH Key is the Only Barrier

**What this means:**
- Entire security model depends on SSH private key (`~/.ssh/mjolnir_*`)
- No secondary authentication (MFA, OTP, etc.)
- Compromised key = unrestricted API access

**Attacks:**
1. **Key Theft** — GitHub commit, laptop theft, CI/CD exposure
2. **Key Exposure** — Stored in plaintext in `~/.ssh`, `.env`, `.bashrc`
3. **Supply Chain** — CI/CD pipelines contain deploy keys
4. **Shared Keys** — Team members use same key (no per-user audit)

**Mitigation:**
- Use unique SSH keys per operator (not shared team keys)
- Rotate SSH keys monthly, immediately on suspected compromise
- Store keys with restricted permissions (`chmod 600`)
- Never commit keys to version control
- Use SSH passphrases or passkeys (hardware tokens)
- Never use SSH agent forwarding with production access

### Critical Limitation 2: No TLS on the API Itself

**What this means:**
- API accepts HTTP (not HTTPS)
- JWT bearer tokens are sent in plaintext over the HTTP channel
- SSH tunnel provides the only encryption

**Risk scenario:**
```
1. Operator accidentally sets up remote forwarding: ssh -R 8000:localhost:4000 bastion
   (intended as temporary, forgotten)
2. Attacker on bastion or bastion network can:
   curl http://localhost:8000/api/vms -H "Authorization: Bearer $JWT"
3. JWT token is visible in plaintext HTTP traffic
4. If token doesn't have short expiry, attacker has persistent access
```

**Mitigation:**
- Implement TLS on the API itself (even self-signed for internal use)
- Use short-lived tokens (exp claim, < 1 hour validity)
- Never use remote SSH forwarding (-R flag)
- Never use SSH agent forwarding (-A flag)

### Critical Limitation 3: No Per-Request Audit Trail

**What this means:**
- All SSH tunnel requests appear as `user_id="localhost"` in logs
- No automatic recording of WHO made WHICH API call
- Hard to detect unauthorized access after the fact

**Example:**
```
SSH tunnel: ssh -i ~/.ssh/mjolnir root@45.76.77.97
Inside tunnel: curl http://localhost:4000/api/vms
Log entry: {"user_id": "localhost", "action": "vms:read", ...}
           ↑ No indication of which SSH user issued this
```

**Mitigation:**
- Extract user from JWT claims and log it
- Audit SSH command history (`~/.bash_history`, `syslog`)
- Monitor `/var/log/auth.log` for SSH connections
- Use SSH command wrapper to log all curl calls

### Critical Limitation 4: Localhost Bypass is Dangerous

**What this means:**
```elixir
config :mjolnir, :auth, bypass_localhost: true
```

When enabled:
- **Anyone who can SSH to the server** (legitimate ops + attackers with stolen key) gets **FULL API ACCESS**
- **No JWT token required**
- **No audit trail** of which user issued which command (all appear as "localhost")

**Risk scenarios:**
1. **Attacker with stolen SSH key**: Can run `curl http://localhost:4000/api/vms` without needing JWT
2. **Accidental exposure**: Bypass left enabled "temporarily" but never removed
3. **Privilege escalation**: Non-root attacker gains root SSH access, then uses API
4. **CI/CD compromise**: Deploy script has bypass enabled + SSH key in CI environment

**Mitigation:**
- **NEVER enable in production**
- If you MUST enable for emergency access:
  1. Document WHY, WHO, and FOR HOW LONG
  2. Disable immediately after use
  3. Audit all API calls made during the window (`grep localhost /var/log/mjolnir/api.log`)
  4. Rotate SSH keys after emergency access
- Do NOT store `bypass_localhost: true` in `config/prod.exs`

### Additional Limitation 5: No Rate Limiting

**What this means:**
- No per-user rate limits on API calls
- No per-IP rate limits
- Brute force is theoretically unchecked (though JWT requirement helps)

**Mitigation:**
- Rely on SSH key security (per Limitation 1)
- Implement rate limiting at the HTTP server layer if needed
- Monitor API access logs for unusual patterns

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

## Best Practices

### SSH Key Management

1. **Generate unique keys per server**
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/mjolnir_45.76.77.97 -C "mjolnir"
   ```

2. **Restrict key permissions**
   ```bash
   chmod 600 ~/.ssh/mjolnir_45.76.77.97
   ```

3. **Use passphrases or hardware keys**
   ```bash
   # Generate with passphrase prompt
   ssh-keygen -t ed25519 -f ~/.ssh/mjolnir_45.76.77.97
   ```

4. **Rotate monthly**
   ```bash
   # Generate new key
   ssh-keygen -t ed25519 -f ~/.ssh/mjolnir_45.76.77.97_new
   # Add public key to server authorized_keys
   # Test new key
   # Remove old key from server authorized_keys
   # Delete old private key
   rm ~/.ssh/mjolnir_45.76.77.97_old
   ```

5. **Monitor SSH access**
   ```bash
   # On server, watch for unauthorized connections
   tail -f /var/log/auth.log | grep "Accepted publickey"
   ```

### Token Management

1. **Use short expiry times**
   ```bash
   # Request token with < 1 hour validity
   # Implement automatic refresh
   ```

2. **Don't store tokens in shell environment**
   ```bash
   # ❌ Bad: stored in ~/.bashrc, visible with `env`
   export MJOLNIR_TOKEN="eyJ..."
   
   # ✅ Better: pass as argument, use credential files with restricted permissions
   just --set MJOLNIR_TOKEN vm-spawn
   ```

3. **Use temporary files with restricted access**
   ```bash
   TOKEN=$(curl -X POST ... | jq -r .access_token)
   # Keep in memory, pass to SSH command
   ssh -i ~/.ssh/mjolnir root@server \
     "curl -H 'Authorization: Bearer $TOKEN' http://localhost:4000/api/vms"
   ```

### SSH Best Practices

1. **Never use agent forwarding**
   ```bash
   # ❌ DANGEROUS
   ssh -A root@bastion
   
   # ✅ Safe
   ssh -i ~/.ssh/mjolnir root@45.76.77.97
   ```

2. **Never use remote forwarding**
   ```bash
   # ❌ DANGEROUS (exposes API on remote host)
   ssh -R 8000:localhost:4000 bastion
   
   # ✅ Safe (local-only)
   ssh -L 8000:localhost:4000 root@45.76.77.97
   # Then: curl http://localhost:8000/api/vms (on your Mac)
   ```

3. **Restrict SSH access in ~/.ssh/config**
   ```ssh-config
   Host mjolnir-prod
     HostName 45.76.77.97
     User root
     IdentityFile ~/.ssh/mjolnir_45.76.77.97
     IdentitiesOnly yes          # Only try specified key
     AddKeysToAgent no           # Don't add to SSH agent
     StrictHostKeyChecking yes   # Reject unknown hosts
     UserKnownHostsFile ~/.ssh/mjolnir_known_hosts
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

## Security Roadmap

### Near Term (Recommended)

- [ ] **Token Expiry Enforcement** — Validate JWT `exp` claim
- [ ] **Per-Request Logging** — Extract user from JWT and log it
- [ ] **SSH Passphrase Support** — Prompt for passphrases, don't store in memory
- [ ] **SSH Key Rotation Automation** — Tooling to rotate keys monthly

### Medium Term

- [ ] **TLS on API itself** — Self-signed certs for internal use, or mutual TLS
- [ ] **Request Signing** — Cryptographic signatures on API calls (in addition to JWT)
- [ ] **Rate Limiting** — Per-user and per-IP rate limits
- [ ] **Audit Logging** — Centralized, tamper-proof audit trail

### Long Term

- [ ] **Centralized Auth** — OAuth2 / OIDC for multi-user, revocation without key rotation
- [ ] **mTLS** — Mutual TLS between clients and API
- [ ] **API Gateway** — Separate gateway for TLS termination, rate limiting, etc.
- [ ] **Hardware MFA** — FIDO2 keys for operator authentication

## References

- `lib/mjolnir/api/auth.ex` — Auth plug implementation
- `lib/mjolnir/api/router.ex` — Endpoint definitions
- `lib/mjolnir/policy/` — Authorization policies
- [OWASP API Security](https://owasp.org/www-project-api-security/)
- [SSH Best Practices](https://man.openbsd.org/ssh_config)
- [JWT Best Practices](https://tools.ietf.org/html/rfc8949)
