# User Story: VM with Secrets

## As a developer, I want to spawn a VM and securely inject secrets so my application can access API keys and database credentials as environment variables — without managing encryption details myself.

---

## The Happy Path

### 1. Spawn a VM with secrets support

```bash
mjolnir vm spawn --secrets persistent
```

Or via API:
```bash
curl -X POST http://localhost:4000/api/vms \
  -H 'Content-Type: application/json' \
  -d '{"secrets_mode": "persistent"}'
```

Response:
```json
{
  "id": "a1b2c3d4-...",
  "status": "running",
  "secrets_mode": "persistent",
  "iroh_ticket": "node1abc..."
}
```

The VM boots normally. The `secrets_mode` flag tells Mjolnir this VM will use encrypted secrets. Under the hood, the guest agent has an Iroh endpoint ready to receive a passphrase — but nothing is encrypted yet.

### 2. Authorize your device to inject secrets

```bash
mjolnir secrets authorize a1b2c3d4 --peer $(mjolnir iroh node-id)
```

Or via API:
```bash
curl -X POST http://localhost:4000/api/vms/a1b2c3d4/authorize-inject \
  -H 'Content-Type: application/json' \
  -d '{"peer_node_id": "your-iroh-node-id"}'
```

This tells the guest agent: "accept secret injection from this specific device." The host relays the authorization via vsock but never sees the passphrase itself.

### 3. Inject your passphrase

```bash
mjolnir secrets inject a1b2c3d4 --passphrase "my-strong-passphrase"
```

This connects directly to the VM via Iroh QUIC (bypassing the host), sends the passphrase, and the guest agent:
1. Creates a 32MB LUKS2 encrypted volume (first time) or opens the existing one
2. Mounts it at `/secrets/`
3. Loads any `.env` files into `/etc/mjolnir/secrets.env`
4. Locks the injection slot — no one can inject again this session

```json
{ "ok": true, "created": true, "mounted": true }
```

### 4. Set your secrets

```bash
mjolnir secrets set a1b2c3d4 DATABASE_URL="postgres://user:pass@host/db" API_KEY="sk-abc123"
```

This also goes over the encrypted Iroh channel:
```json
{ "ok": true, "count": 2 }
```

### 5. Use your application — secrets just work

```bash
mjolnir vm exec a1b2c3d4 'echo $DATABASE_URL'
# postgres://user:pass@host/db

mjolnir vm exec a1b2c3d4 'python app.py'
# App starts with DATABASE_URL and API_KEY available in os.environ
```

Every command executed in the VM automatically sources the secrets. Your application reads them as standard environment variables — no SDK, no config files, no Mjolnir-specific code.

---

## What the User Doesn't Need to Know

All of this happens transparently:

- **LUKS2 encryption** with AES-XTS-plain64, Argon2id key derivation
- **Passphrase zeroed from memory** after LUKS open (zeroize crate)
- **Keyfile written with mode 0600**, overwritten with zeros before deletion
- **Environment key validation** prevents shell injection via malicious key names
- **Atomic one-shot injection** prevents re-injection after initial unlock
- **Peer identity verification** using Iroh's cryptographic NodeId
- **secrets.env file permissions** set to 0600

The user's mental model is simply:
1. Spawn VM with secrets
2. Unlock it with a passphrase
3. Set key-value pairs
4. Everything just works as env vars

---

## Secrets Modes

| Mode | Description | Dormancy | Use Case |
|------|-------------|----------|----------|
| `none` | No secrets support (default) | Allowed | Stateless compute, testing |
| `persistent` | LUKS volume on virtio-fs | Blocked | Production apps with credentials |
| `ephemeral` | Secrets exist only while running | Allowed | Short-lived tasks, CI/CD |

### Why persistent blocks dormancy

When a VM goes dormant (calls `handle_done`), Mjolnir snapshots its filesystem and stops it. A persistent LUKS volume means the encrypted file is part of the snapshot — but the passphrase is only in memory. If the VM were to become dormant and later restore, it would need the passphrase again. To keep the security model simple and prevent accidental data loss, VMs with `secrets_mode: persistent` cannot go dormant.

---

## Lifecycle Diagram

```
  SPAWN ────────────────────────────────────────────────> RUNNING
    │                                                        │
    │  secrets_mode: persistent                              │
    │                                                        │
    ▼                                                        │
  AUTHORIZE PEER ──> INJECT PASSPHRASE ──> SET SECRETS       │
    (host relays       (Iroh direct,         (Iroh direct)   │
     via vsock)         bypasses host)                        │
                           │                                 │
                           ▼                                 │
                    LUKS MOUNTED ──────────────────────> EXEC WITH SECRETS
                    /secrets/ available                  env vars auto-sourced
                           │
                           │  handle_done?
                           ▼
                    BLOCKED (persistent mode)
                    "secrets_prevent_dormancy"
```

---

## Secret File Layout

Users can also store files (certificates, keys) on the encrypted volume:

```
/secrets/
├── .env                    # Primary key-value secrets
├── env.d/
│   ├── database.env        # Group secrets by service
│   └── stripe.env
├── files/
│   ├── tls-cert.pem        # Arbitrary secret files
│   └── service-account.json
└── metadata.json           # Auto-generated metadata
```

All `.env` files (root + `env.d/*.env`) are merged and exported. Files in `files/` are just stored — applications read them directly from `/secrets/files/`.

---

## Error Scenarios

| Scenario | What Happens |
|----------|--------------|
| Inject without authorizing | Connection rejected: "unauthorized peer" |
| Inject twice | Second attempt rejected: "secrets already injected" |
| Wrong passphrase on existing volume | LUKS open fails, injection slot released for retry |
| `set_env` before inject | Rejected: "secrets not yet injected" |
| Invalid env key (`FOO;rm -rf /`) | Rejected: "Invalid env key" |
| VM exec without secrets | Works fine — `[ -f secrets.env ] && . secrets.env` is a no-op when the file doesn't exist |

---

## Future: CLI Commands (Phase 4)

```bash
# Full lifecycle
mjolnir secrets init <vm-id>                     # Create LUKS volume (inject passphrase)
mjolnir secrets unlock <vm-id>                    # Open existing volume
mjolnir secrets set <vm-id> KEY=VALUE [KEY=VALUE] # Set env vars
mjolnir secrets push <vm-id> < .env               # Push entire .env file
mjolnir secrets list <vm-id>                      # List env var keys (not values)
mjolnir secrets status <vm-id>                    # Check mount/inject state
mjolnir secrets close <vm-id>                     # Unmount and close volume
```
