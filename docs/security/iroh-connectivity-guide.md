# Iroh Connectivity & P2P Security Guide

This guide explains how Mjolnir uses Iroh for peer-to-peer VM connectivity, including threat models, configuration options, and best practices.

## Quick Start

When you spawn a VM with `enable_iroh: true`, the guest agent automatically:
1. Generates or loads a persistent ED25519 keypair
2. Connects to the Iroh relay network for NAT traversal
3. Reports its node ID (public key) to the host
4. Returns a z32-encoded 52-character ticket for connection

```bash
# Via Justfile
just vm-spawn                    # Returns web_url with ticket
just vm-await-pty <id>          # Waits for Iroh endpoint online
just vm-ticket <id>             # Get ticket as z32 string

# Via API
POST /api/vms {"enable_iroh": true}
GET  /api/vms/<id>/ticket
POST /api/vms/<id>/await-pty    # Poll until ready (includes relay connection time)
```

## Connection Model

```
┌─────────────┐                              ┌──────────────┐
│   Client    │                              │   VM Guest   │
│ (your laptop)                              │ (Iroh node)  │
└──────┬──────┘                              └──────┬───────┘
       │                                            │
       │  QUIC/TLS 1.3                             │
       │  (ED25519 peer verification)              │
       └────────────────────────────────────────────┘
                    Direct (if reachable)
                    OR via Iroh relay
                    (if behind symmetric NAT)
```

**Relay Role**: The Iroh relay is a STUN-like service—it helps peers discover each other's addresses and relays packets when direct connection isn't possible. It does NOT decrypt QUIC traffic (TLS 1.3 is end-to-end). If direct connection succeeds, relay is bypassed entirely.

## Security Properties

### What's Encrypted
- **QUIC payload**: TLS 1.3, end-to-end. Relay operator cannot see plaintext.
- **Peer identity**: ED25519 public key (the z32 ticket). Verified in TLS handshake.

### What's NOT Encrypted
- **Relay metadata**: Relay sees connection timing, source IPs, destination node IDs, byte counts. No content privacy from relay.
- **DNS**: z32 subdomains are resolved via standard DNS (Cloudflare, etc.). Resolver sees your VM ticket lookups.

### Peer Authorization

By default, any client knowing your z32 ticket can connect. The ticket is derived from your node ID (public key), which is unique but non-secret.

**Secret injection** (LUKS passphrase, etc.) is protected by a whitelist:
- Guest maintains `AUTHORIZED_INJECT_PEERS` set
- Only node IDs in this set can use `SECRET_INJECT_ALPN`
- Host can authorize new peers via:
  ```bash
  POST /api/vms/<id>/authorize-inject-peer {"node_id": "<z32 peer id>"}
  ```

## Configuration & Persistence

### Key Persistence

The guest agent stores its keypair at `/etc/mjolnir/iroh.key` (32 bytes, raw binary). When you snapshot a VM:

```bash
just snap-create <id> my-snapshot      # Default: generates NEW key for next spawn
just vm-spawn-from my-snapshot \
  --preserve-iroh-key                  # Keep original key from snapshot
```

Use `preserve_iroh_key: true` if you want downstream VMs to have the same Iroh identity (useful for access control—existing clients remain authorized).

### Relay Configuration

Iroh relay URL is compiled into the guest agent binary. Current: `https://iroh.worldtree.network` (Fastly-hosted, run by Worldtree).

To use a different relay (self-hosted), rebuild the guest agent with:
```rust
// native/mjolnir_guest_agent/src/iroh.rs
const RELAY_URL: &str = "https://your-relay.example.com";
```

Then deploy with `just deploy-full --agent`.

## Threat Model

### Threat 1: Relay Operator Observes Connection Metadata

**Attacker**: Relay operator (ISP-like position)
**Exposure**: Connection timing, frequency, volume, peer IPs, node IDs
**Mitigation**:
- Use direct connection (same LAN/WAN) when possible
- Consider self-hosted relay if relay operator is untrusted
- No viable mitigation for metadata itself (inherent to IP-layer protocols)

### Threat 2: VM Compromise Leaks Keypair

**Attacker**: Malicious guest code running in VM
**Exposure**: Secret key → attacker can impersonate VM's Iroh node, decrypt past sessions (if recorded)
**Mitigation**:
- Isolate secrets to separate VMs
- Use `SECRET_INJECT_ALPN` only for bootstrap (short-lived passphrases)
- Don't use same VM for untrusted workloads + secret handling
- Snapshot VM before injection, rotate key if compromise suspected

### Threat 3: Ticket Leaked, Unauthorized Access

**Attacker**: Obtains your z32 ticket via GitHub, logs, etc.
**Exposure**: Shell access, TCP port forwarding (depending on guest firewall)
**Mitigation**:
- Treat tickets like SSH private keys — don't commit to repos
- Rotate VM / generate new ticket if leaked: `just vm-stop <id> && just vm-spawn`
- Use guest-side firewall rules to restrict inbound ports
- Short-lived tickets: snapshot → spawn fresh with new key regularly

### Threat 4: Man-in-the-Middle (MITM) on Relay

**Attacker**: Relay operator or ISP intercepts relay packets
**Exposure**: Cannot decrypt TLS 1.3, but can observe which peers tried to connect
**Mitigation**:
- QUIC/TLS 1.3 provides confidentiality; no additional mitigation needed
- If relay is untrusted, use direct connection or self-hosted relay

## Debugging Iroh Connectivity

```bash
# Check if Iroh endpoint is online
just iroh-status <id>
# Returns: {"ready": true, "node_id": "...", "endpoints": [...], "relay": "..."}

# Force relay reconnection (useful if relay seems stale)
POST /api/vms/<id>/reconfigure-iroh

# Get full ticket + endpoint metadata (for debugging NAT/relay issues)
GET /api/vms/<id>/iroh-info
# Returns: {"ticket": "z32...", "iroh_json": "full endpoint address JSON"}
```

## Common Issues

### "Connection timed out" to ticket

**Likely causes**:
1. VM hasn't reached Iroh relay yet (relay connection takes ~5-10s after boot)
   - Solution: Wait longer, use `await-pty` endpoint
2. Relay is unreachable from client location
   - Solution: Check `iroh-status`, if relay is stale, call `reconfigure-iroh`
3. Guest firewall blocks inbound (if using custom guest networking)
   - Solution: Check `/etc/mjolnir/vm.json` for IP assignment, test ping first

### "Permission denied" on shell access

**Causes**:
1. Guest SSH not configured — use `configure_ssh(authorized_keys)` at boot
2. Shell user doesn't exist — default shell runs as `root`
3. Guest shell crashed — check guest logs via vsock exec

### Secret injection fails

**Causes**:
1. Peer not whitelisted — check `GET /api/vms/<id>/iroh-info`, call `authorize-inject-peer`
2. Guest not listening on `SECRET_INJECT_ALPN` — `enable_iroh: true` required at spawn time
3. LUKS not configured — passphrase has nowhere to write

## Best Practices

1. **Generate unique keypair per environment**: Don't reuse `preserve_iroh_key` across dev/staging/prod
2. **Rotate keys periodically**: Snapshot baseline → spawn fresh VMs monthly
3. **Audit authorized inject peers**: List via `GET /api/vms/<id>/iroh-info`, revoke unused peers
4. **Use short-lived VM tickets**: If ticket is exposed, retiring the VM is quickest fix
5. **Test relay failover**: Run `just chaos-iroh-relay-down` to simulate relay outage
6. **Monitor Iroh endpoint health**: Add `/api/vms/<id>/iroh-status` to your monitoring dashboard

## References

- [Iroh documentation](https://iroh.computer/docs)
- [docs/security/network-transport.md](./network-transport.md) — Lower-level protocol details
- [docs/security/secrets-architecture.md](./secrets-architecture.md) — LUKS secret injection protocol
