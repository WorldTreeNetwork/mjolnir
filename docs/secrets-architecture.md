# Mjolnir Secrets Architecture

> **See also:** `docs/encryption-and-security.md` for how secrets fit into the broader security model — three-tier storage (secrets are Tier 3), four encryption layers, and the full threat model.

## Overview

Mjolnir provides encrypted secrets management for VMs using LUKS2 encrypted volumes, with passphrase injection over Iroh's end-to-end encrypted QUIC connections. Secrets are automatically loaded as environment variables — applications consume them like any standard env-based configuration (e.g., `DATABASE_URL`, `API_KEY`).

**Design principles:**
- **Zero knowledge on host** — the host never sees passphrases or decrypted secrets
- **Battle-tested crypto** — LUKS2 (dm-crypt), AES-XTS, Argon2id
- **Transparent to applications** — secrets appear as environment variables, sourced automatically on every `exec`
- **One-shot injection** — passphrase can only be injected once per VM session (atomic guard)
- **Peer-authenticated delivery** — only authorized Iroh peers can inject secrets

---

## Architecture

```
  Client (laptop)                     Host (Elixir)                    Guest (VM)
  ─────────────────                   ──────────────                   ──────────────

  1. Spawn VM ──────────────────────> POST /api/vms
                                      │ spawn VM process
                                      │ boot guest agent ─────────────> agent starts
                                      │                                 Iroh endpoint ready
                                      │                                 │
  2. Authorize peer ────────────────> POST /api/vms/:id/               │
     (my Iroh node_id)                 authorize-inject                 │
                                      │ vsock: configure_secrets_auth ──> add to AUTHORIZED_INJECT_PEERS
                                      │                                 │
  3. Inject passphrase ─────────────────────────────────────────────────> SECRET_INJECT_ALPN
     (direct Iroh QUIC)               (bypasses host entirely)          │ verify peer is authorized
                                                                        │ create/open LUKS volume
                                                                        │ mount /secrets
                                                                        │ load .env → /etc/mjolnir/secrets.env
                                                                        │ mark injected (one-shot)
                                                                        ✓
  4. Use secrets ───────────────────> POST /api/vms/:id/exec
     (exec commands)                  │ vsock: exec ────────────────────> sh -c '[ -f secrets.env ] && . secrets.env; <cmd>'
                                                                        │ $DATABASE_URL, $API_KEY, etc. available
```

### Why Iroh, Not Vsock?

The host controls the vsock channel — it can read all traffic. For secrets, we need a path that bypasses the host entirely. Iroh provides:

1. **End-to-end encryption** — QUIC with peer-specific keys, even the relay can't read content
2. **NAT traversal** — clients inject from anywhere (laptop, CI, other VMs)
3. **Peer identity** — each Iroh endpoint has a cryptographic NodeId; the guest validates the connecting peer against an authorized list
4. **No host involvement** — passphrase travels client → Iroh relay → guest, never touching the Elixir host process

---

## Storage Layout

### Inside the Guest VM

```
/var/lib/mjolnir/
  secrets.luks              # LUKS2 encrypted loopback file (32MB default)

/dev/mapper/
  mjolnir-secrets           # dm-crypt mapped device (after unlock)

/secrets/                   # Mount point (ext4 on LUKS)
  .env                      # KEY=VALUE pairs (primary secrets file)
  env.d/                    # Additional .env files (merged alphabetically)
    database.env
    api-keys.env
  files/                    # Arbitrary secret files (certs, keys, etc.)
  metadata.json             # Volume metadata (version, created_at)

/etc/mjolnir/
  secrets.env               # Auto-generated: `export KEY='value'` (mode 0600)
  vm.json                   # VM identity (vm_id, api_url)

/etc/profile.d/
  mjolnir-secrets.sh        # Sources secrets.env for interactive shells
```

### LUKS2 Configuration

| Parameter | Value |
|-----------|-------|
| Format | LUKS2 |
| Cipher | aes-xts-plain64 |
| Key size | 512-bit |
| Hash | sha256 |
| PBKDF | argon2id |
| Min volume size | 32 MB (LUKS2 headers ~16MB) |

---

## Security Model

### Threat Model

| Threat | Mitigation |
|--------|-----------|
| Host reads secrets in transit | Iroh QUIC bypasses host; secrets never traverse vsock |
| Unauthorized peer injects secrets | `AUTHORIZED_INJECT_PEERS` allowlist checked on connection |
| Re-injection after compromise | Atomic one-shot guard (`compare_exchange`) — inject only once per session |
| Passphrase in memory | Zeroized after use via `zeroize` crate |
| Keyfile left on disk | Overwritten with zeros before deletion; mode 0600 |
| Malicious env key names | Validated against `[A-Za-z_][A-Za-z0-9_]*` |
| secrets.env readable by other users | Written with mode 0600 |
| Secrets survive snapshot | LUKS file is part of VM filesystem — encrypted at rest |

### One-Shot Injection Guard

The injection is protected by an atomic `compare_exchange` on a static `AtomicBool`:

```rust
pub fn try_claim_injection() -> bool {
    SECRETS_INJECTED.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).is_ok()
}
```

This prevents TOCTOU races — only the first caller succeeds. If LUKS init/open fails, the claim is released so injection can be retried.

### Mutation Guards

Operations that modify secrets (`set_env`, `push_env`, `close`) require that injection has already completed. This prevents manipulation of the secrets volume before it's been properly initialized.

---

## Secret Inject Protocol

**ALPN:** `mjolnir-secret-inject/1`

The protocol uses a single bidirectional QUIC stream with JSON request/response:

### Actions

#### `inject` (default)

Creates or opens the LUKS volume and loads environment variables.

```json
// Request
{
  "action": "inject",
  "passphrase": "my-strong-passphrase",
  "init_size_mb": 32          // optional, only for first-time creation
}

// Response (success — new volume)
{ "ok": true, "created": true, "mounted": true }

// Response (success — existing volume)
{ "ok": true, "created": false, "mounted": true }

// Response (already injected)
{ "ok": false, "error": "secrets already injected" }
```

#### `status`

Check the current state of the secrets volume.

```json
// Request
{ "action": "status" }

// Response
{
  "ok": true,
  "mounted": true,
  "injected": true,
  "luks_exists": true
}
```

#### `set_env`

Set specific environment variables (merge with existing). Requires prior injection.

```json
// Request
{
  "action": "set_env",
  "entries": {
    "DATABASE_URL": "postgres://...",
    "API_KEY": "sk-..."
  }
}

// Response
{ "ok": true, "count": 2 }
```

#### `push_env`

Replace entire .env contents. Requires prior injection.

```json
// Request
{
  "action": "push_env",
  "content": "DATABASE_URL=postgres://...\nAPI_KEY=sk-...\n"
}

// Response
{ "ok": true }
```

#### `close`

Unmount and close the LUKS volume. Requires prior injection.

```json
// Request
{ "action": "close" }

// Response
{ "ok": true, "mounted": false }
```

---

## API Endpoints

### Spawn with Secrets Mode

```http
POST /api/vms
Content-Type: application/json

{
  "secrets_mode": "persistent"
}
```

`secrets_mode` values:
- `"persistent"` — VM has a LUKS secrets volume; prevents dormancy (can't snapshot encrypted state safely)
- `"ephemeral"` — Secrets exist only while VM is running
- `"none"` (default) — No secrets support

### Authorize an Inject Peer

```http
POST /api/vms/:id/authorize-inject
Content-Type: application/json

{
  "peer_node_id": "abc123def456..."
}
```

Tells the guest agent to add this Iroh NodeId to its authorized inject peers list. Must be called before the client attempts secret injection.

---

## How Environment Variables Work

1. **Storage**: Secrets are stored as `KEY=VALUE` in `/secrets/.env` (on the encrypted LUKS volume)
2. **Export**: On injection (and on `set_env`/`push_env`), the agent generates `/etc/mjolnir/secrets.env` with `export KEY='value'` lines (mode 0600, shell-safe quoting)
3. **Auto-source**: Every `exec` command is wrapped: `[ -f /etc/mjolnir/secrets.env ] && . /etc/mjolnir/secrets.env; <command>`
4. **Interactive shells**: `/etc/profile.d/mjolnir-secrets.sh` sources the env file for login shells (bash, sh)

This means applications don't need any Mjolnir-specific code — they just read environment variables as usual:

```python
import os
db_url = os.environ["DATABASE_URL"]
```

```javascript
const apiKey = process.env.API_KEY;
```

---

## Guest Agent Components

### `secrets.rs` — LUKS Engine

| Function | Purpose |
|----------|---------|
| `init_secrets_volume(size, passphrase)` | Create LUKS file, format, mount, create dirs |
| `open_secrets_volume(passphrase)` | Open existing LUKS file and mount |
| `close_secrets_volume()` | Unmount, close LUKS, detach loop device |
| `load_env_vars()` | Parse .env files → write /etc/mjolnir/secrets.env |
| `set_env_vars(entries)` | Merge key-value pairs into .env |
| `push_env_content(content)` | Replace .env contents |
| `try_claim_injection()` | Atomic one-shot guard (compare_exchange) |
| `is_valid_env_key(key)` | Validate key against `[A-Za-z_][A-Za-z0-9_]*` |

### `iroh.rs` — Secret Inject Protocol

| Function | Purpose |
|----------|---------|
| `authorize_inject_peer(node_id)` | Add NodeId to authorized peers set |
| `handle_secret_inject(conn)` | Accept QUIC stream, dispatch by action |
| `handle_inject_action(req)` | Atomic claim → LUKS init/open → load env |
| `handle_status_action()` | Return mount/inject/exists state |
| `handle_close_action()` | Close LUKS volume |
| `handle_set_env_action(req)` | Merge env vars (guarded by is_injected) |
| `handle_push_env_action(req)` | Replace env content (guarded by is_injected) |

---

## Kernel Requirements

The guest kernel must have these options enabled:

```
CONFIG_BLK_DEV_DM=y        # Device mapper
CONFIG_DM_CRYPT=y           # dm-crypt (LUKS)
CONFIG_CRYPTO_XTS=y         # XTS block cipher mode
CONFIG_CRYPTO_AES=y         # AES cipher
```

The rootfs must include `cryptsetup-bin` and `kmod` packages.

---

## Future Work

- **CLI `secrets` commands**: `mjolnir secrets init`, `secrets set`, `secrets push`, `secrets list`, `secrets status`
- **IdentiKey S3 sync**: Sync encrypted LUKS files to S3 for backup/restore across VM instances
- **Secret rotation**: Re-encrypt with a new passphrase without unmounting
- **Audit logging**: Log injection attempts (success/failure) with peer identity
