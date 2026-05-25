# Network Isolation & VM Segmentation

This guide covers Mjolnir's network architecture, VM-to-VM isolation guarantees, and considerations for multi-tenant deployments.

## Network Architecture

Each VM is connected to the host via a dedicated TAP (tunnel/tap) virtual Ethernet device. There is **no shared Ethernet bridge** — VMs cannot see each other at the link layer.

```
┌─────────────────────────────────────────────┐
│             Host (Linux)                    │
│                                             │
│  IP Forwarding: enabled                     │
│  iptables NAT: 10.200.0.0/10 → egress iface│
│                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐ │
│  │ tap-vm1  │  │ tap-vm2  │  │ tap-vm3  │ │
│  │ (no IP)  │  │ (no IP)  │  │ (no IP)  │ │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘ │
│       │             │             │        │
│  route: /32 via tap-vm1, /32 via tap-vm2, /32 via tap-vm3 │
│       │             │             │        │
└───────┼─────────────┼─────────────┼────────┘
        │             │             │
      ▼               ▼             ▼
   ┌──────┐       ┌──────┐     ┌──────┐
   │ VM 1 │       │ VM 2 │     │ VM 3 │
   │ 10.  │       │ 10.  │     │ 10.  │
   │200.  │       │200.  │     │200.  │
   │0.2   │       │0.3   │     │0.4   │
   └──────┘       └──────┘     └──────┘
```

### IP Allocation (Deterministic)

Each VM's IP is derived from `SHA256(vm_uuid)` in the **10.200.0.0/10** range (10.192.0.0 — 10.255.255.255, ~4.2M addresses).

**Rationale**:
- Deterministic: same VM UUID always gets same IP (useful for configuration)
- Private range: RFC 1918, safe to NAT outbound
- Large space: supports millions of concurrent VMs
- Avoids .0 and .255 in last octet (broadcast protection)

**Example**:
```bash
VM UUID: 550e8400-e29b-41d4-a716-446655440000
SHA256:  abc123... (first 4 bytes)
Hash → 10.245.67.42   # Deterministic, repeatable
```

### MAC Address (Deterministic)

Generated from `SHA256(vm_uuid)`, format: `02:FC:00:xx:xx:xx`
- Byte 0 = `02` (locally administered, unicast)
- Bytes 1-2 = `FC:00` (Mjolnir prefix)
- Bytes 3-5 = Last 3 bytes of SHA256 hash

Ensures ARP tables are stable across reboots (same VM UUID = same MAC).

## Isolation Guarantees

### What IS Isolated

✅ **Link-layer isolation**: VMs cannot sniff each other's Ethernet frames (no shared bridge)

✅ **IP routing isolation**: VMs reach each other only via /32 routes through the host (like point-to-point links)

✅ **VLAN-like behavior**: Without explicit host routing, VMs cannot communicate

✅ **ARP isolation**: No ARP broadcasts cross TAP boundaries (host proxy-ARPs on behalf of guests)

### What IS NOT Isolated

❌ **Network layer isolation**: Host forwards traffic between VMs (if guest firewall allows)
- VMs can reach each other if host IP forwarding is enabled
- No network namespace per VM
- Guest firewalling is the second line of defense

❌ **DNS isolation**: All VMs resolve through the same nameserver (no per-VM DNS policy)

❌ **Outbound Internet**: All VMs NAT through the same egress interface
- Cannot distinguish VMs by outbound IP (all appear as host IP to remote servers)
- Rate limits / blacklists apply globally, not per-VM

❌ **Metadata/timing**: Host can observe packet volume, timing, inter-VM connections

## Multi-Tenant Security Model

If running multiple users' VMs on shared hardware, network isolation is layer 1 of 3:

```
┌──────────────────────────────────────┐
│  Layer 3: Guest Firewall Rules       │
│  (each user configures their own)    │
└──────────────────────────────────────┘
           ▲
           │
┌──────────────────────────────────────┐
│  Layer 2: Host Routing Policy        │
│  (restrict which VMs can reach each) │
└──────────────────────────────────────┘
           ▲
           │
┌──────────────────────────────────────┐
│  Layer 1: Link-Layer Isolation (TAP) │
│  (implemented, baseline)             │
└──────────────────────────────────────┘
```

### Layer 1 (TAP Isolation) — Built-in

Each VM's TAP device is isolated at the kernel level. A compromised VM running as root cannot:
- Bridge its TAP to other TAPs (kernel prevents)
- Sniff neighbor traffic (not on shared medium)
- Inject frames with fake source MACs (MAC spoofing is prevented by TAP enforcement)

### Layer 2 (Routing Policy) — Operator Responsibility

To prevent VM-to-VM communication, add firewall rules on the host:

```bash
# Deny all inter-VM traffic (10.200.0.0/10 to 10.200.0.0/10)
sudo iptables -A FORWARD -s 10.200.0.0/10 -d 10.200.0.0/10 -j DROP

# Allow specific VM pairs
sudo iptables -A FORWARD -s 10.200.0.2 -d 10.200.0.3 -j ACCEPT
sudo iptables -A FORWARD -s 10.200.0.3 -d 10.200.0.2 -j ACCEPT
```

**Embed in ufw**:
```bash
# /etc/ufw/before.rules
*filter
:FORWARD ACCEPT [0:0]
-A FORWARD -s 10.200.0.0/10 -d 10.200.0.0/10 -j DROP
COMMIT
```

### Layer 3 (Guest Firewall) — User Responsibility

Each VM user must configure guest-side firewall:

```bash
# Inside VM (iptables)
sudo iptables -A INPUT -s 10.200.0.0/10 -j DROP     # Deny all inbound from VMs
sudo iptables -A OUTPUT -d 10.200.0.0/10 -j ACCEPT  # Allow outbound to specific VMs

# Or use ufw (Ubuntu)
sudo ufw default deny incoming
sudo ufw allow from 10.200.0.1  # Only allow from host
```

## Common Scenarios

### Scenario 1: Development (Single-User, All VMs Trusted)

**Network**: No restrictions needed
```
┌─────────────────────────────────┐
│ Single dev machine              │
│ ├─ dev-api                      │
│ ├─ dev-db                       │
│ ├─ dev-cache                    │
│ VMs talk to each freely, NAT out│
└─────────────────────────────────┘
```

**Configuration**:
- Spawn VMs with default isolation (TAP only)
- No additional routing rules needed
- Guest firewalls can be permissive (dev-friendly)

### Scenario 2: Multi-Tenant SaaS (Strict Isolation)

**Network**: Layer 2 + Layer 3 enforcement
```
┌──────────────────────────────────────┐
│ Host (shared Mjolnir)                │
│                                      │
│ alice@               bob@             │
│ ├─ api (10.200.0.2)  ├─ api (10.200.0.100) │
│ └─ db (10.200.0.3)   └─ db (10.200.0.101)  │
│                                      │
│ Host routing: alice VMs cannot reach │
│ bob VMs (iptables DROP rule)        │
└──────────────────────────────────────┘
```

**Configuration**:
```bash
# Host policy: isolate by subnet
# Split 10.200.0.0/10 into per-tenant subnets
# alice: 10.200.0.0/16 (10.200.0.0 — 10.200.255.255)
# bob:   10.201.0.0/16 (10.201.0.0 — 10.201.255.255)

# Allocation: modify lib/mjolnir/network.ex to hash on (user_id, vm_uuid)

# Rules:
sudo iptables -A FORWARD -s 10.200.0.0/16 -d 10.200.0.0/16 -j ACCEPT  # alice-alice OK
sudo iptables -A FORWARD -s 10.201.0.0/16 -d 10.201.0.0/16 -j ACCEPT  # bob-bob OK
sudo iptables -A FORWARD -s 10.200.0.0/16 -d 10.201.0.0/16 -j DROP    # alice→bob blocked
sudo iptables -A FORWARD -s 10.201.0.0/16 -d 10.200.0.0/16 -j DROP    # bob→alice blocked
```

### Scenario 3: Workload Isolation (Different Sensitivity Levels)

**Network**: Layer 3 (guest) enforcement + Layer 2 (host) if needed

```
┌──────────────────┐    ┌──────────────────┐
│ PUBLIC tier      │    │ PRIVATE tier     │
│ (web frontends)  │    │ (databases)      │
│ ├─ api-1         │    │ ├─ postgres-1    │
│ └─ api-2         │    │ └─ redis-1       │
└──────────────────┘    └──────────────────┘

Public VMs may initiate → Private
Private VMs must NOT → Public
```

**Configuration**:
```bash
# Host rules (if public tier is compromised)
# Deny outbound from public subnet to private
sudo iptables -A FORWARD -s 10.200.0.0/17 -d 10.200.128.0/17 -j DROP

# Guest rules (hardening inside private tier)
# Reject inbound from private VMs not in allowlist
sudo iptables -A INPUT -s 10.200.0.0/17 -j DROP
sudo iptables -A INPUT -s 10.200.128.5 -j ACCEPT  # Allow only api-1
```

## NAT & Outbound Internet

All VMs share the host's outbound IP. Outbound masquerading is configured via:

```bash
# iptables rule (auto-added on startup)
sudo iptables -t nat -A POSTROUTING -s 10.200.0.0/10 -o eth0 -j MASQUERADE
```

**Implications**:
- All VMs appear as the host's IP to external services
- Remote servers cannot distinguish traffic from different VMs
- IP-based rate limiting / blacklisting affects all VMs (shared fate)
- Reverse DNS on host IP is shared

**Workaround**: Route some VMs through external proxies:
```bash
# Inside VM, use external proxy for outbound
export HTTP_PROXY=https://proxy.example.com:8080
curl https://api.example.com
```

## Proxy ARP & Gateway Behavior

The host enables **proxy ARP** on each TAP device. This means:

```
VM 1 (10.200.0.2) wants to reach VM 2 (10.200.0.3):

1. VM 1 ARP: "Who has 10.200.0.3?"
2. Host (tap-vm2): "I have 10.200.0.3" (proxy)
3. VM 1 sends to host TAP
4. Host routes via tap-vm2 to VM 2
```

**Security note**: The host appears as the gateway for all hosts in the subnet. A compromised VM can ARP-spoof, but only against the host (since VMs don't see each other's ARP).

## Troubleshooting

### "Ping timeout" between VMs

**Cause**: Host routing rules deny inter-VM traffic
**Fix**:
```bash
# Check if rules exist
sudo iptables -L FORWARD

# Allow temporary for testing
sudo iptables -A FORWARD -s 10.200.0.2 -d 10.200.0.3 -j ACCEPT
ping -c 1 10.200.0.3  # Should work now

# If works, rules are correct
```

### "No route to host" (external server)

**Cause**: NAT rule missing or disabled
**Fix**:
```bash
# Check MASQUERADE rule exists
sudo iptables -t nat -L POSTROUTING

# If missing, re-add (Mjolnir auto-adds on startup)
just ensure-nat

# Check IP forwarding is enabled
cat /proc/sys/net/ipv4/ip_forward  # Should be 1
```

### VM sees wrong gateway IP

**Cause**: Proxy ARP not configured on TAP
**Fix**:
```bash
# Inside VM
route -n  # Gateway should be 10.x.x.1 (host side TAP)

# On host, check proxy_arp
cat /proc/sys/net/ipv4/conf/tap-vm1/proxy_arp  # Should be 1
```

## Design Decisions

**Why /32 point-to-point instead of shared bridge?**
- Simplicity: no VLAN configuration needed
- Isolation: TAP boundaries are hard kernel guarantees
- Flexibility: per-VM traffic shaping via /32 routes
- Debugging: each VM's traffic is obvious (unique route)

**Why deterministic IP from hash?**
- Stability: rebuilding same VM gets same IP (DNS, config files)
- Reproducibility: test scenarios are repeatable
- No DHCP server: less infrastructure to manage

**Why NAT instead of routed?**
- Internet-safe: VMs never expose private IPs to external networks
- Host-centric: all traffic appears to come from host
- Simplicity: guests don't need host route announcements

## References

- `lib/mjolnir/network.ex` — TAP device & routing implementation
- [Linux kernel TAP driver](https://www.kernel.org/doc/html/latest/networking/tuntap.html)
- [iptables NAT howto](https://www.netfilter.org/documentation/HOWTO/NAT-HOWTO.html)
- docs/security/network-transport.md — Protocol-level details
