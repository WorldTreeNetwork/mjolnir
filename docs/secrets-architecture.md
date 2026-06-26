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
                                                                        │ load .env → /run/mjolnir/secrets.env
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

/run/mjolnir/               # tmpfs (RAM) — never persisted, never snapshotted
  secrets.env               # Auto-generated: `export KEY='value'` (mode 0600)

/etc/mjolnir/
  vm.json                   # VM identity (vm_id, api_url)

/etc/profile.d/
  mjolnir-secrets.sh        # Sources /run/mjolnir/secrets.env for interactive shells
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
| Secrets survive snapshot | Rendered plaintext lives on tmpfs (`/run/mjolnir/secrets.env`) and is never captured by a BTRFS snapshot; only the LUKS file is on the rootfs, and it is ciphertext at rest |

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
- `"managed"` — LUKS secrets volume whose passphrase is generated and **escrowed by the host**. The host re-injects it over vsock on every boot, including dormancy wake — so managed VMs **can go dormant** and scale to zero. See [Managed Mode](#managed-mode-host-escrowed-secrets) below.
- `"persistent"` — LUKS secrets volume whose passphrase is held by a remote **Iroh peer** (host-blind). Because only that peer can supply the passphrase, the host cannot autonomously wake the VM, so **dormancy is refused**.
- `"ephemeral"` — Secrets exist only while VM is running
- `"none"` (default) — No secrets support

---

## Managed Mode (Host-Escrowed Secrets)

`persistent` mode is host-blind by design — the passphrase only ever lives in a remote Iroh peer, so nobody can unlock the volume when the host auto-wakes a dormant VM on an incoming message. That is exactly why `persistent` refuses dormancy. `managed` mode makes the opposite trade: the **host** holds the passphrase, so it can re-unlock secrets autonomously on wake. This enables scale-to-zero for VMs that need secrets, at the cost of host-blindness.

### Trust model

| Property | `persistent` | `managed` |
|----------|-------------|-----------|
| Who holds the passphrase | Remote Iroh peer | The host |
| Host can read decrypted secrets | No | **Yes** |
| Survives host compromise | Yes | **No** |
| Can go dormant / wake-on-message | No | **Yes** |
| Delivery channel | Iroh QUIC (E2E) | vsock (host↔guest) |

`managed` is **not** zero-knowledge. It is appropriate when the host is already trusted with the workload (e.g. it spawns and execs into the VM anyway) and the goal is operational autonomy, not protection from a compromised host. What the LUKS layer still buys you in this mode:

- **Offsite/backup snapshots stay opaque.** A snapshot's `secrets.luks` is ciphertext; the passphrase is *not* in the snapshot (it lives in the host escrow dir, off the data volume), so a leaked or synced snapshot is useless alone.
- **Disk theft / decommission** is safe as long as the escrow directory isn't on the stolen volume.
- **Per-VM blast radius.** Each VM gets an independent random passphrase.

### What the host escrows (and where)

The host escrows **only the passphrase** — never the secret material itself. The `.env` content lives inside the LUKS volume, which is on the VM rootfs subvolume and is therefore captured (as ciphertext) by `btrfs subvolume snapshot`. So waking a dormant VM is just *re-opening an already-present encrypted volume* with the escrowed passphrase.

```
Host (off the data volume):
  /var/lib/mjolnir/escrow/<vm_id>     # 32-byte random passphrase, mode 0600
                                       # NEVER inside @vms/ or @snapshots/ → never snapshotted
```

`btrfs subvolume snapshot` only copies the VM's own `@vms/<uuid>` subvolume. The escrow directory is a plain host path, never shared into the guest via virtiofs and never inside `@vms`, so it is structurally impossible for it to appear in a snapshot.

### Lifecycle

```
  Host (Elixir)                              Guest (VM)
  ─────────────                              ──────────

  Spawn secrets_mode=managed
  │ boot, wait for agent
  │ escrow miss → generate passphrase
  │ write /var/lib/mjolnir/escrow/<id> (0600)
  │ vsock: inject_secrets{passphrase, init_size_mb} ──> create LUKS, mount /secrets, load env
  ✓ VM running with secrets

  POST /api/vms/:id/secrets {entries}  ──────────────> set_env → /secrets/.env (encrypted),
                                                        render /run/mjolnir/secrets.env (tmpfs)

  handle_done (dormancy)
  │ sync + pause + btrfs snapshot (ciphertext .luks captured)
  │ KEEP escrow entry
  ✓ dormant

  incoming message → wake
  │ clone rootfs from snapshot (.luks present)
  │ boot, wait for agent
  │ escrow HIT → read passphrase
  │ vsock: inject_secrets{passphrase} (no init_size) ─> open existing LUKS, load env
  ✓ secrets transparently restored, no human in the loop

  kill / destroy
  │ delete escrow entry  (dormancy does NOT delete it)
```

### vsock delivery

Unlike `persistent` (Iroh ALPN), `managed` delivers the passphrase over the existing vsock control channel via an `inject_secrets` request, dispatched directly into the same `secrets.rs` LUKS engine (`init_secrets_volume` / `open_secrets_volume` / `load_env_vars`). The per-session one-shot guard (`try_claim_injection`) resets on each fresh agent process, so re-injection on every boot/wake is expected and safe.

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
2. **Export**: On injection (and on `set_env`/`push_env`), the agent generates `/run/mjolnir/secrets.env` (tmpfs — plaintext never touches the rootfs or a snapshot) with `export KEY='value'` lines (mode 0600, shell-safe quoting)
3. **Auto-source**: Every `exec` command is wrapped: `[ -f /run/mjolnir/secrets.env ] && . /run/mjolnir/secrets.env; <command>`
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
| `load_env_vars()` | Parse .env files → write /run/mjolnir/secrets.env (tmpfs) |
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
