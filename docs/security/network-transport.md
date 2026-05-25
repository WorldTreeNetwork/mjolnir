# Network & Transport Security

How Mjolnir isolates VMs, secures communication channels, and terminates
external connections.

## Network Isolation

Each VM gets a dedicated TAP device (`mj-<short_uuid>`) with a /32 route
on the host. There is no shared broadcast domain — VMs cannot see each
other's traffic at the Ethernet level.

**IP allocation** (`lib/mjolnir/network.ex`): Deterministic from
`SHA256(vm_id)` in the `10.0.0.0/8` range. Same VM UUID always gets the
same IP and MAC. Last octets avoid `.0` and `.255` to prevent broadcast
confusion.

**NAT**: Host-side `iptables -t nat MASQUERADE` on the egress interface
gives VMs outbound internet. NAT rules are embedded in `/etc/ufw/before.rules`
so they survive `ufw reload` (a past incident taught us raw `iptables -t nat`
rules get wiped).

**Isolation guarantees**:
- Point-to-point: each VM has its own TAP, no bridge
- No ARP: proxy ARP on the host responds on behalf of guests
- No cross-VM routing: /32 routes mean the host must explicitly forward
- VMs share the host routing table but cannot inject routes

**What's NOT isolated**: VMs can reach each other via IP if the host forwards
(which it does for NAT). Full network namespace isolation per VM is not
implemented — VMs rely on guest-side firewalling for ingress control.

## vsock (Host-Guest Control Channel)

vsock is the primary control channel between Mjolnir and the guest agent.
It runs over a kernel-mediated Unix domain socket, multiplexed by channel:

| Channel | Purpose | Format |
|---|---|---|
| 0 | JSON control (exec, ping, configure) | JSON over length-prefixed frames |
| 1-255 | Binary PTY streams | Raw bytes over length-prefixed frames |

**Wire format**: `[1-byte channel][4-byte BE length][payload]`. Max frame
size: 65,536 bytes (enforced to prevent memory exhaustion).

**CID allocation**: Each VM gets a unique 32-bit Context ID derived from
`MD5(vm_uuid)` in range `[3, 0xFFFFFFFF)`. The hypervisor enforces CID
isolation — one VM cannot forge vsock packets from another CID.

**Encryption**: None. vsock is a local transport (analogous to a Unix pipe).
The trust boundary is the hypervisor process — if Cloud Hypervisor is
compromised, vsock traffic is exposed. This is acceptable because the
hypervisor already has full access to VM memory.

## Iroh (P2P Encrypted Transport)

VMs use [Iroh](https://iroh.computer) for peer-to-peer connectivity.
Each VM generates an ED25519 keypair; the public key becomes the node ID.

**Connection flow**:
1. Guest agent starts Iroh endpoint, registers with relay for NAT traversal
2. Host receives the node ID and z32-encodes it into a 52-character "ticket"
3. Clients connect via QUIC/TLS 1.3 directly or through the relay

**Encryption**: QUIC provides end-to-end encryption (TLS 1.3). The relay
operator can observe connection timing and metadata but cannot decrypt
payload.

**ALPNs (Application Layer Protocol Negotiation)**:
| ALPN | Purpose |
|---|---|
| `SHELL_ALPN` | Interactive shell sessions |
| `TCP_FWD_ALPN` | Port forwarding (used by gateway) |
| `SECRET_INJECT_ALPN` | LUKS passphrase injection (whitelist-guarded) |

**Secret injection authorization**: The `SECRET_INJECT_ALPN` is protected
by a peer whitelist (`AUTHORIZED_INJECT_PEERS` in the guest agent). Only
explicitly authorized Iroh node IDs can inject secrets. See
`docs/secrets-architecture.md` for the full injection protocol.

## Gateway (HTTPS Termination)

The Rust-based gateway (`mjolnir-gateway`) bridges HTTPS traffic to VMs
via Iroh.

**TLS**: rustls with hot-reloadable certificates via `ArcSwap`. ACME
renewal supported. SIGHUP reloads certs atomically without dropping
in-flight connections.

**Routing**:
- Subdomains are z32-decoded to Iroh node IDs
- Each VM gets a URL: `https://<ticket>.vm.worldtree.network`
- Apex domains can declare `fallthrough = "iroh"` or `fallthrough = "none"`
- Malformed z32 subdomains fail silently (404)

**Trust model**: The gateway terminates TLS and re-encrypts to the VM via
Iroh QUIC. It can observe plaintext HTTP between TLS termination and Iroh
encryption. This is the standard reverse-proxy model (identical to nginx
or Cloudflare).

## Trust Boundaries Summary

```
Internet
  │
  │ HTTPS (TLS 1.3, ACME cert)
  ▼
Gateway (mjolnir-gateway)
  │
  │ Iroh QUIC (TLS 1.3, ED25519 peer identity)
  ▼
Guest VM (mjolnir-agent)
  │
  │ vsock (unencrypted, kernel-mediated)
  ▼
Host (BEAM / Mjolnir)
  │
  │ HTTP (localhost only, JWT or bypass)
  ▼
API Consumer (SSH-tunneled curl, or direct localhost)
```

Each arrow is a trust boundary. The gateway sees plaintext between TLS
termination and Iroh. The host sees vsock traffic. The API is
localhost-only with optional JWT auth.
