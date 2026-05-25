# Mjolnir Security Documentation

This directory contains comprehensive security documentation for Mjolnir's network architecture, transport protocols, and operational security practices.

## Quick Navigation

Start here based on your role:

### **For Operators / SREs**
- **[Network Isolation Guide](./network-isolation-guide.md)** — TAP devices, IP allocation, multi-tenant isolation, iptables rules
- **[API Transport Security](./api-transport-security.md)** — JWT auth, SSH tunneling, localhost bypass, key management
- **[Host Hardening](./host-hardening.md)** — Kernel settings, firewall tuning, compliance

### **For Developers / Integrators**
- **[Iroh Connectivity Guide](./iroh-connectivity-guide.md)** — P2P shell access, relay configuration, secret injection
- **[Network & Transport Fundamentals](./network-transport.md)** — Protocol-level details (vsock, QUIC, ALPNs)
- **[Threat Model](./threat-model.md)** — Attack scenarios, trust boundaries, security assumptions

### **For Security Auditors**
- **[Threat Model](./threat-model.md)** — Comprehensive threat analysis
- **[Network & Transport Fundamentals](./network-transport.md)** — Protocol security properties
- This README — Quick reference for all components

## Architecture Overview

Mjolnir's security model is **defense-in-depth** with three independent layers:

```
┌───────────────────────────────────────────────────────────────┐
│                         Internet                              │
│                                                               │
│  TLS 1.3 (HTTPS)                                             │
│  ACME certificate renewal (rustls)                           │
│                                                               │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────┐
│            Gateway (mjolnir-gateway)                         │
│  ├─ Host header routing (z32 decoding)                       │
│  └─ Local TCP backends or Iroh TCP_FWD_ALPN fallthrough     │
│                                                               │
│  TLS 1.3 QUIC (per ALPN)                                    │
│  ED25519 peer identity                                       │
│  Iroh relay for NAT traversal                               │
│                                                               │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────┐
│         Guest VM (mjolnir-agent, Iroh node)                 │
│  ├─ SHELL_ALPN — interactive shells                         │
│  ├─ TCP_FWD_ALPN — port forwarding                          │
│  └─ SECRET_INJECT_ALPN — LUKS passphrase injection          │
│                                                               │
│  No encryption (QUIC is upstream, handled by Iroh)         │
│  Channel multiplexing (channel 0=JSON, 1-255=PTY)          │
│  Max frame size: 65,536 bytes                               │
│                                                               │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────┐
│              Host (Mjolnir / BEAM)                           │
│  ├─ vsock connection to guest (unencrypted)                │
│  ├─ TAP device + /32 routing per VM                         │
│  ├─ iptables MASQUERADE for NAT                             │
│  │                                                            │
│  └─ HTTP API (localhost:4000 only)                          │
│     ├─ JWT auth (remote, optional)                          │
│     └─ Localhost bypass (localhost, optional)               │
│                                                               │
│  SSH tunnel for remote access                               │
│  (SSH key auth, encrypted transport)                        │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

## Security Properties Summary

| Component | Layer | Encryption | Auth | Isolation |
|-----------|-------|-----------|------|-----------|
| **HTTPS (Gateway)** | Edge | TLS 1.3 | SNI cert | Per domain |
| **Iroh QUIC** | P2P | TLS 1.3 + ED25519 | Peer identity | Per node ID |
| **vsock (host↔guest)** | Local | None | Kernel CID | Per hypervisor |
| **Network (TAP)** | Link | None | IP routing | TAP isolation |
| **HTTP API** | Mgmt | None (SSH tunnel) | JWT or localhost | Ownership-based |

## Trust Boundaries

### Threat Model: Who Can See What

```
┌──────────────────────────────────────────────────────────┐
│ Internet Attacker (unauthenticated)                      │
│ Can see: HTTPS handshake, ciphertext, domain name        │
│ Cannot: decrypt QUIC/TLS payload                         │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│ Relay Operator (Iroh relay)                              │
│ Can see: connection timing, peer IPs, node IDs, volume   │
│ Cannot: decrypt TLS 1.3 payload                          │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│ Gateway Operator (web gateway)                           │
│ Can see: plaintext HTTP between TLS termination & Iroh   │
│ Can see: Host headers, request paths, payloads           │
│ Cannot: decrypt Iroh QUIC (re-encrypted upstream)        │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│ Hypervisor (Cloud Hypervisor binary)                     │
│ Can see: all VM memory, vsock traffic, TAP frames        │
│ Cannot: access outside VMs or host OS                    │
│ (Compromise = full VM compromise)                        │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│ Host Operator (Mjolnir, BEAM)                            │
│ Can see: vsock traffic, iptables rules, API requests     │
│ Can see: which VMs communicate (via routing decisions)   │
│ Cannot: decrypt Iroh or QUIC payload                     │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│ Authorized User (SSH key holder)                         │
│ Can: access API via SSH tunnel, spawn/manage VMs         │
│ Cannot: access other users' VMs (ownership-based)        │
└──────────────────────────────────────────────────────────┘
```

## Security Checklist

### Pre-Production Deployment

- [ ] **Network Isolation**
  - [ ] Read [Network Isolation Guide](./network-isolation-guide.md)
  - [ ] Configure multi-tenant iptables rules if needed
  - [ ] Test VM-to-VM connectivity restrictions
  - [ ] Document your isolation model (Layer 1/2/3)

- [ ] **API Security**
  - [ ] Enable JWT auth OR localhost bypass (not both in production)
  - [ ] Configure SSH keys for all operators
  - [ ] Rotate SSH keys quarterly
  - [ ] Monitor API access logs

- [ ] **Iroh / P2P Connectivity**
  - [ ] Test relay connectivity from your network
  - [ ] Document relay latency & failover procedure
  - [ ] Configure secret injection whitelist if using LUKS
  - [ ] Test key rotation (preserve_iroh_key behavior)

- [ ] **Host Hardening**
  - [ ] Read [Host Hardening](./host-hardening.md)
  - [ ] Enable SELinux or AppArmor (optional but recommended)
  - [ ] Configure sysctl kernel parameters (ip_forward, etc.)
  - [ ] Set up auditd for sensitive operations

- [ ] **TLS / Certificates**
  - [ ] Configure ACME issuer for gateway
  - [ ] Test certificate renewal (SIGHUP reload)
  - [ ] Verify no cert expiry in production

- [ ] **Monitoring & Audit**
  - [ ] Ship API logs to centralized logging (ELK, Datadog, etc.)
  - [ ] Monitor vsock connection errors
  - [ ] Alert on iptables rule changes
  - [ ] Weekly security review of access logs

### Incident Response

- [ ] **Suspected VM Compromise**
  - [ ] Snapshot VM (preserve evidence)
  - [ ] Stop VM immediately (`just vm-stop <id>`)
  - [ ] Rotate Iroh keypair if secret injection was used
  - [ ] Review vsock logs for suspicious commands
  - [ ] Check iptables logs for unauthorized network activity

- [ ] **API Key/Token Leaked**
  - [ ] Revoke token immediately (auth issuer responsibility)
  - [ ] Rotate SSH keys
  - [ ] Review API logs for unauthorized access
  - [ ] Force re-auth for all users

- [ ] **Relay Unavailable**
  - [ ] VMs without direct connectivity will timeout
  - [ ] Check relay URL & network reachability
  - [ ] Call `POST /api/vms/<id>/reconfigure-iroh` to reconnect
  - [ ] If persistent, switch to self-hosted relay (see Iroh guide)

- [ ] **Suspected Host Compromise**
  - [ ] Offline host immediately
  - [ ] Preserve syslog & iptables logs
  - [ ] Restore from known-good snapshot or rebuild
  - [ ] Rotate all API credentials

## Key Security Assumptions

Mjolnir's security model assumes:

1. **Cloud Hypervisor is trustworthy** — if hypervisor is compromised, VMs are compromised
2. **Kernel is trustworthy** — if kernel has vulnerabilities, TAP isolation is breached
3. **SSH keys are kept secure** — SSH key = full API access
4. **Network environment is at least semi-trusted** — relay operator can observe metadata (not mitigated)
5. **Iroh relay is reachable** — if relay is blocked, P2P connectivity fails (no fallback to direct-only by default)

## External References

- [Iroh Documentation](https://iroh.computer/docs) — P2P protocol
- [QUIC Protocol (RFC 9000)](https://www.rfc-editor.org/rfc/rfc9000) — Transport layer
- [TLS 1.3 (RFC 8446)](https://www.rfc-editor.org/rfc/rfc8446) — Encryption
- [Linux TAP/TUN Driver](https://www.kernel.org/doc/html/latest/networking/tuntap.html) — Network isolation
- [OWASP API Security Top 10](https://owasp.org/www-project-api-security/)

## Document Versions

| Document | Version | Last Updated | Author |
|----------|---------|--------------|--------|
| Network Isolation Guide | 1.0 | 2026-05-25 | Duke Jones |
| API Transport Security | 1.0 | 2026-05-25 | Duke Jones |
| Iroh Connectivity Guide | 1.0 | 2026-05-25 | Duke Jones |
| Network & Transport | 1.0 | 2026-02-27 | Mjolnir Team |
| Threat Model | 1.0 | 2026-02-27 | Mjolnir Team |
| Host Hardening | 1.0 | 2026-02-27 | Mjolnir Team |

## Questions?

- **How do I?** → Check the relevant guide above
- **Is it secure to?** → See Threat Model
- **What happens if?** → See Incident Response section
- **Code question?** → Check source code references in each guide
