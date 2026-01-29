# VM Networking Troubleshooting

## Architecture Overview

Mjolnir uses flat /32 routing for VM networking with proxy ARP:

```
┌─────────────────────────────────────────────────────────────┐
│                         HOST                                 │
│                                                             │
│   IP forwarding enabled                                     │
│   iptables MASQUERADE for 10.200.0.0/10                     │
│                                                             │
│   ┌─────────┐     ┌─────────┐     ┌─────────┐              │
│   │ mj-XXX  │     │ mj-YYY  │     │ mj-ZZZ  │              │
│   │ (no IP) │     │ (no IP) │     │ (no IP) │              │
│   └────┬────┘     └────┬────┘     └────┬────┘              │
│        │               │               │                    │
│   route: /32       route: /32      route: /32              │
│   via tap          via tap         via tap                 │
└─────────────────────────────────────────────────────────────┘
         │               │               │
    ┌────┴────┐     ┌────┴────┐     ┌────┴────┐
    │ VM 1    │     │ VM 2    │     │ VM N    │
    │10.200.  │     │10.200.  │     │10.200.  │
    │  X.Y/32 │     │  A.B/32 │     │  C.D/32 │
    └─────────┘     └─────────┘     └─────────┘
```

**Key points:**
- Range: `10.200.0.0/10` (~4 million VMs)
- Each VM gets one IP (e.g., `10.200.45.123`)
- Host adds `/32` route per VM via its TAP device
- Guest uses point-to-point link (no gateway IP)
- Host enables **proxy ARP** on TAP so guest can reach external IPs
- Host NATs traffic via iptables MASQUERADE

## How Proxy ARP Works

With traditional subnet routing, when a guest wants to reach `8.8.8.8`:
1. Guest checks: "Is 8.8.8.8 on my subnet (e.g., 10.200.45.0/24)?" → No
2. Guest ARPs for the **gateway** (e.g., 10.200.45.1)
3. Gateway responds with its MAC address
4. Guest sends packets to gateway's MAC, gateway forwards them

With our **/32 point-to-point** setup:
1. Guest has `10.200.45.123/32` - a single address, no subnet
2. Guest has route: `default dev eth0` - no gateway IP specified
3. When guest wants to reach `8.8.8.8`, it ARPs for `8.8.8.8` **directly**
4. Without proxy ARP: nobody responds → `ip neigh` shows `FAILED` → no connectivity
5. **With proxy ARP**: host's TAP interface responds "I can reach 8.8.8.8, send to me"
6. Guest sends packets to TAP's MAC, host receives and forwards via NAT

```
Guest: "Who has 8.8.8.8? Tell 10.200.45.123"
       ↓
   [TAP interface with proxy_arp=1]
       ↓
Host:  "8.8.8.8 is at 02:FC:00:xx:xx:xx" (TAP's MAC)
       ↓
Guest: Sends packet to TAP's MAC
       ↓
Host:  Receives on TAP → routes → NAT → internet
```

**Why /32 + proxy ARP instead of subnets?**
- No IP waste: each VM gets exactly 1 IP, not a /24 (254 wasted)
- Simpler: no per-VM subnet configuration
- Flat routing: all VMs in one big pool
- Scales to millions of VMs without subnet exhaustion

**Enabling proxy ARP:**
```bash
# Per interface (done automatically by Mjolnir)
echo 1 > /proc/sys/net/ipv4/conf/mj-XXXXXXXX/proxy_arp

# Verify
cat /proc/sys/net/ipv4/conf/mj-XXXXXXXX/proxy_arp  # Should be 1
```

## Quick Checks

### 1. IP forwarding enabled?

```bash
cat /proc/sys/net/ipv4/ip_forward  # Should be 1
```

If not:
```bash
echo 1 > /proc/sys/net/ipv4/ip_forward
# Make persistent:
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
```

### 2. NAT rule exists?

```bash
iptables -t nat -L POSTROUTING -v | grep 10.200
```

Should show something like:
```
    0     0 MASQUERADE  all  --  any    any     10.200.0.0/10       anywhere
```

If missing:
```bash
iptables -t nat -A POSTROUTING -s 10.200.0.0/10 -j MASQUERADE
```

### 3. FORWARD rules exist?

```bash
iptables -L FORWARD -v | grep 10.200
```

If missing:
```bash
iptables -A FORWARD -s 10.200.0.0/10 -j ACCEPT
iptables -A FORWARD -d 10.200.0.0/10 -j ACCEPT
```

### 4. TAP interface exists and is up?

```bash
ip link show mj-<vm_id_prefix>
# Example: ip link show mj-abc12345
```

Should show:
```
5: mj-abc12345: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...
```

### 5. Route to guest exists?

```bash
ip route | grep 10.200
# Should show: 10.200.X.Y dev mj-XXXXXXXX scope link
```

### 6. Guest has IP configured?

```elixir
Mjolnir.VM.exec(vm.id, "ip addr show eth0")
Mjolnir.VM.exec(vm.id, "ip route")
```

Should show:
```
inet 10.200.X.Y/32 scope global eth0
default dev eth0 scope link
```

## Common Issues

### "Network unreachable" in guest

**Symptoms:** Guest can't reach any external host.

**Check:**
1. Guest IP configured?
   ```elixir
   Mjolnir.VM.exec(vm.id, "ip addr")
   ```

2. Guest default route exists?
   ```elixir
   Mjolnir.VM.exec(vm.id, "ip route")
   ```
   Should show: `default dev eth0 scope link`

3. Host has route to guest?
   ```bash
   ip route get 10.200.X.Y
   ```

### "curl: (6) Could not resolve host"

**Symptoms:** Guest can ping IPs but not resolve DNS names.

**Check DNS config:**
```elixir
Mjolnir.VM.exec(vm.id, "cat /etc/resolv.conf")
```

Should contain:
```
nameserver 8.8.8.8
nameserver 1.1.1.1
```

**Test with IP directly:**
```elixir
Mjolnir.VM.exec(vm.id, "curl -I 93.184.216.34")  # example.com
```

### Host can't reach guest

**Check:**
1. Route exists?
   ```bash
   ip route get 10.200.X.Y
   ```

2. TAP is up?
   ```bash
   ip link show mj-XXXX
   ```

3. Firecracker has network interface configured?
   Check VM spawn logs for network interface setup.

### Guest ARP fails (`ip neigh` shows FAILED)

**Symptoms:** Guest can't reach any IP. `ip neigh` shows:
```
8.8.8.8 dev eth0 FAILED
1.1.1.1 dev eth0 FAILED
```

**Cause:** Proxy ARP not enabled on TAP interface.

**Fix:**
```bash
# Check proxy_arp status
cat /proc/sys/net/ipv4/conf/mj-XXXXXXXX/proxy_arp  # Should be 1

# Enable if missing
echo 1 > /proc/sys/net/ipv4/conf/mj-XXXXXXXX/proxy_arp
```

**Why this happens:** With /32 point-to-point routing, the guest has no gateway.
When it wants to reach 8.8.8.8, it ARPs for 8.8.8.8 directly. Without proxy ARP,
nobody responds. With proxy ARP, the host TAP says "send it to me, I'll forward."

### TAP creation fails

**Symptoms:** VM spawn fails with TAP error.

**Check:**
1. Running as root (or CAP_NET_ADMIN)?
2. No name collision?
   ```bash
   ip link | grep mj-
   ```

3. Too many interfaces? (unlikely, but check limits)

### Traffic not reaching internet

**Check NAT is working:**
```bash
# On host, watch traffic
tcpdump -i any -n src 10.200.0.0/10

# In guest
Mjolnir.VM.exec(vm.id, "curl https://example.com")
```

Should see packets from 10.200.X.Y on TAP, then source-rewritten packets on external interface.

## Packet Capture

### Capture TAP traffic for a VM

```bash
tcpdump -i mj-<vm_id_prefix> -n
```

### Watch all VM traffic

```bash
tcpdump -i any -n net 10.200.0.0/10
```

### Check NAT is working

```bash
# See packets before NAT (on TAP)
tcpdump -i mj-XXXX -n

# See packets after NAT (on external interface)
tcpdump -i eth0 -n 'icmp and dst 8.8.8.8'
```

## Verify Full Path

```bash
# 1. Guest sends packet
Mjolnir.VM.exec(vm.id, "ping -c1 8.8.8.8")

# 2. Host should see it on TAP
tcpdump -i mj-XXXX -c1 icmp

# 3. Host should NAT and forward to external interface
tcpdump -i eth0 -c1 'icmp and dst 8.8.8.8'

# 4. Reply comes back, reverse NAT, delivered to guest
```

## Elixir Debug Commands

```elixir
# Get VM's network config
vm = Mjolnir.VM.list() |> hd()
vm.net_config
# => %{tap_name: "mj-abc12345", guest_ip: "10.200.45.123", guest_mac: "02:FC:00:..."}

# Test guest connectivity
Mjolnir.VM.exec(vm.id, "ping -c1 8.8.8.8")
Mjolnir.VM.exec(vm.id, "curl -s https://example.com | head -5")

# Check guest network config
Mjolnir.VM.exec(vm.id, "ip addr show eth0")
Mjolnir.VM.exec(vm.id, "ip route")
Mjolnir.VM.exec(vm.id, "cat /etc/resolv.conf")
```

## Resetting Networking

If networking is in a bad state, you can reset:

```bash
# Remove all Mjolnir TAPs
for tap in $(ip link show | grep 'mj-' | cut -d: -f2 | tr -d ' '); do
    ip link del "$tap" 2>/dev/null || true
done

# Remove all /32 routes in VM range
ip route | grep '10.200' | while read route; do
    ip route del $route 2>/dev/null || true
done

# Re-add NAT rules
iptables -t nat -A POSTROUTING -s 10.200.0.0/10 -j MASQUERADE
iptables -A FORWARD -s 10.200.0.0/10 -j ACCEPT
iptables -A FORWARD -d 10.200.0.0/10 -j ACCEPT
```

---

## Iroh Shell Troubleshooting

VMs include an Iroh endpoint for NAT-traversing shell access. When working, you can shell into a VM from anywhere using a ticket.

### Quick Checks

**1. Is shell ready?**
```elixir
vm = Mjolnir.VM.list() |> hd()
IO.inspect(vm.shell_ready)    # true or false
IO.inspect(vm.iroh_node_id)   # 52-char base32 string
IO.inspect(vm.iroh_ticket)    # longer address string
```

**2. Can guest reach internet?**
Shell requires outbound connectivity for relay connection:
```elixir
Mjolnir.VM.exec(vm.id, "curl -s https://example.com | head -1")
```

**3. Guest agent running?**
```elixir
Mjolnir.VM.exec(vm.id, "ps aux | grep mjolnir")
# Should show mjolnir-agent process
```

**4. Guest agent logs?**
```elixir
Mjolnir.VM.exec(vm.id, "journalctl -u mjolnir-agent -n 50")
```

### Common Issues

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| `shell_ready: false` | Network not configured | Check Phase 1 networking |
| `iroh_ticket: nil` | Relay connection failed | Check guest can reach internet |
| Connection hangs | Firewall blocking UDP | Check iptables FORWARD rules |
| PTY not working | Missing shell | Check rootfs has /bin/bash or /bin/zsh |

### Iroh Endpoint Details

- **ALPN:** `mjolnir-shell/1`
- **Key location:** `/etc/mjolnir/iroh.key` (generated if missing)
- **Relay:** Uses n0's public relays by default
- **Protocol:** QUIC with TLS encryption

### Verifying Iroh Connectivity

**On guest (if you can exec):**
```elixir
# Check if iroh is listening
Mjolnir.VM.exec(vm.id, "ss -unp | grep mjolnir")

# Check DNS/relay reachability
Mjolnir.VM.exec(vm.id, "curl -I https://relay.iroh.network")
```

**Packet capture (on host):**
```bash
# Watch QUIC traffic (UDP port 443 for relay, random high ports for direct)
tcpdump -i any -n 'udp and (port 443 or portrange 49152-65535)'
```

### API Reference

```elixir
# Get ticket for VM
{:ok, ticket} = Mjolnir.VM.get_ticket(vm.id)

# Get node ID
{:ok, node_id} = Mjolnir.VM.node_id(vm.id)

# Wait for shell to become ready (with timeout)
{:ok, ticket} = Mjolnir.VM.await_shell(vm.id, 30_000)
```

### Binary Size Note

Adding Iroh increases the guest agent binary from ~1.4 MB to ~24 MB. This is expected due to the QUIC/TLS networking stack.
