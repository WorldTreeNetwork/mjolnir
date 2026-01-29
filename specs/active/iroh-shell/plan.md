# Technical Plan: NAT-Traversing Shell Access

**Task ID:** iroh-shell
**Created:** 2026-01-28
**Status:** Ready for Implementation
**Spec:** [spec.md](./spec.md)

---

## Overview

This plan breaks down the iroh-shell feature into implementable phases. Each phase is self-contained and delivers testable functionality.

---

## Phase 1: Guest Outbound Networking

**Goal:** VMs can reach the internet via host NAT

**Duration estimate:** 1-2 focused sessions

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         HOST                                 │
│                                                             │
│   IP forwarding enabled                                     │
│   iptables MASQUERADE for 10.200.0.0/10                     │
│                                                             │
│   ┌─────────┐     ┌─────────┐     ┌─────────┐              │
│   │ tap-1   │     │ tap-2   │     │ tap-N   │              │
│   │ (no IP) │     │ (no IP) │     │ (no IP) │              │
│   └────┬────┘     └────┬────┘     └────┬────┘              │
│        │               │               │                    │
│   route: 10.200.0.2/32 10.200.0.3/32  10.200.X.Y/32        │
│        via tap-1       via tap-2       via tap-N            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
         │               │               │
    ┌────┴────┐     ┌────┴────┐     ┌────┴────┐
    │ VM 1    │     │ VM 2    │     │ VM N    │
    │10.200.  │     │10.200.  │     │10.200.  │
    │  0.2/32 │     │  0.3/32 │     │  X.Y/32 │
    │ p2p link│     │ p2p link│     │ p2p link│
    └─────────┘     └─────────┘     └─────────┘
```

**IP Addressing Scheme:**
- Range: `10.200.0.0/10` (~4 million VMs per host)
- Each VM gets a single /32 address (no per-VM subnet)
- Flat routing: host adds `/32` route per VM via its TAP
- Guest uses point-to-point link (default route via TAP device)
- Configurable via `config :mjolnir, :vm_network, subnet: "10.200.0.0/10"`

### File Changes

#### 1. `lib/mjolnir/network.ex` (NEW)

```elixir
defmodule Mjolnir.Network do
  @moduledoc """
  TAP interface management for VM networking.

  Uses flat /32 routing: each VM gets a single IP, host adds a route via TAP.
  Host provides NAT via iptables MASQUERADE.

  Default range: 10.200.0.0/10 (~4 million VMs)
  """

  @doc """
  Create and configure a TAP interface for a VM.

  1. Creates TAP device (no IP on host side)
  2. Allocates guest IP from pool
  3. Adds /32 route to guest via TAP
  4. Enables proxy ARP on TAP

  Returns {:ok, %{tap_name: String.t(), guest_ip: String.t(), guest_mac: String.t()}}
  """
  def create_tap(vm_id)

  @doc """
  Delete a TAP interface and remove its route.
  """
  def delete_tap(tap_name, guest_ip)

  @doc """
  Generate a deterministic MAC address from VM ID.
  Format: 02:FC:00:xx:xx:xx (locally administered, Firecracker prefix)
  """
  def generate_mac(vm_id)

  @doc """
  Allocate an IP address for a VM based on its ID.
  Uses consistent hashing to map VM ID to IP in configured range.
  Returns guest_ip as string (e.g., "10.200.45.123")
  """
  def allocate_ip(vm_id)

  @doc """
  Get the configured VM network range.
  Default: "10.200.0.0/10"
  """
  def network_range()
end
```

**Implementation details:**
- Use `System.cmd("ip", ...)` for TAP/route management
- TAP name: `mj-{short_id}` (first 8 chars of vm_id)
- MAC generation: hash vm_id, take 3 bytes, prefix with `02:FC:00`
- IP allocation: consistent hash of vm_id into 10.200.0.0/10 range
- Host commands per VM:
  ```bash
  ip tuntap add mj-XXXX mode tap
  ip link set mj-XXXX up
  ip route add 10.200.X.Y/32 dev mj-XXXX
  ```
- Guest configuration (via agent):
  ```bash
  ip addr add 10.200.X.Y/32 dev eth0
  ip link set eth0 up
  ip route add default dev eth0  # point-to-point, no gateway IP needed
  ```

#### 2. `lib/mjolnir/firecracker/config.ex` (MODIFY)

Add network interface configuration:

```elixir
# Add to typedstruct
field(:network_interface, map(), default: nil)

# Add new function
@doc """
Generates the network-interface configuration for Firecracker API.
"""
def network_interface(%__MODULE__{} = config) do
  if config.network_interface do
    %{
      "iface_id" => "eth0",
      "guest_mac" => config.network_interface.guest_mac,
      "host_dev_name" => config.network_interface.tap_name
    }
  else
    nil
  end
end
```

#### 3. `lib/mjolnir/vm.ex` (MODIFY)

Add TAP lifecycle to VM spawn:

```elixir
# In do_boot/1, after BTRFS clone, before configure_vm:
{:ok, net_config} <- Mjolnir.Network.create_tap(state.id),

# Pass net_config to configure_vm
:ok <- configure_vm(socket_path, vsock_path, net_config, %{state.config | ...}),

# In configure_vm/4, add network interface:
:ok <- maybe_put_network_interface(socket_path, net_config),

# In cleanup/1:
if state.net_config, do: Mjolnir.Network.delete_tap(state.net_config.tap_name)
```

#### 4. `lib/mjolnir/firecracker/client.ex` (MODIFY)

Add network interface API call:

```elixir
@doc """
Configure a network interface.
"""
def put_network_interface(socket_path, iface_id, config) do
  put(socket_path, "/network-interfaces/#{iface_id}", config)
end
```

#### 5. `scripts/bootstrap-host.sh` (MODIFY)

Add networking setup section after `setup_directories`:

```bash
setup_networking() {
    log_section "Setting Up VM Networking"

    # VM subnet - 10.200.0.0/10 gives us ~4 million VMs
    # Using 10.200.x.x avoids conflicts with common LAN ranges (10.0.x, 10.1.x)
    local vm_subnet="10.200.0.0/10"

    # Enable IP forwarding
    log_info "Enabling IP forwarding..."
    echo 1 > /proc/sys/net/ipv4/ip_forward

    # Make persistent
    if ! grep -q "net.ipv4.ip_forward" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    fi

    # Add NAT rule for VM subnet
    if ! iptables -t nat -C POSTROUTING -s "$vm_subnet" -j MASQUERADE 2>/dev/null; then
        log_info "Adding NAT masquerade rule for $vm_subnet..."
        iptables -t nat -A POSTROUTING -s "$vm_subnet" -j MASQUERADE
    else
        log_info "NAT rule already exists"
    fi

    # Allow forwarding for VM traffic
    if ! iptables -C FORWARD -s "$vm_subnet" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -s "$vm_subnet" -j ACCEPT
        iptables -A FORWARD -d "$vm_subnet" -j ACCEPT
    fi

    # Make iptables rules persistent
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
    elif command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

    log_success "VM networking configured (subnet: $vm_subnet)"
}
```

Add to `install_base_packages`:
```bash
apt-get install -y iptables-persistent
```

#### 6. `scripts/build-rootfs.sh` (MODIFY)

Configure guest networking in rootfs:

```bash
# Add to rootfs setup, after installing packages:

# Configure networking as manual (agent will set it up)
cat > "$ROOTFS/etc/network/interfaces.d/eth0" << 'EOF'
# Configured by Mjolnir guest agent on boot
auto eth0
iface eth0 inet manual
EOF

# Create network setup script that guest agent will call
# Uses point-to-point routing (no gateway IP needed)
cat > "$ROOTFS/usr/local/bin/mjolnir-network-setup" << 'EOF'
#!/bin/bash
# Called by guest agent with: $1=ip (e.g., 10.200.45.123)
# Point-to-point link - default route goes directly via eth0
set -e
IP="$1"

ip addr add "${IP}/32" dev eth0
ip link set eth0 up

# Point-to-point default route (no gateway needed)
ip route add default dev eth0

# DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

echo "Network configured: $IP"
EOF
chmod +x "$ROOTFS/usr/local/bin/mjolnir-network-setup"
```

#### 7. `native/mjolnir_guest_agent/src/main.rs` (MODIFY)

Add network configuration request handler:

```rust
#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Request {
    #[serde(rename = "exec")]
    Exec { id: String, command: String },
    #[serde(rename = "ping")]
    Ping { id: String },
    #[serde(rename = "configure_network")]
    ConfigureNetwork {
        id: String,
        ip: String,  // Just the IP, e.g., "10.200.45.123"
    },
}

// In handle_request:
Request::ConfigureNetwork { id, ip } => {
    info!("Configuring network: ip={}", ip);
    let output = Command::new("/usr/local/bin/mjolnir-network-setup")
        .arg(&ip)
        .output();
    match output {
        Ok(out) => Response::ExecResponse {
            id,
            exit_code: out.status.code().unwrap_or(-1),
            stdout: String::from_utf8_lossy(&out.stdout).to_string(),
            stderr: String::from_utf8_lossy(&out.stderr).to_string(),
        },
        Err(e) => Response::ExecResponse {
            id,
            exit_code: -1,
            stdout: String::new(),
            stderr: format!("Failed to configure network: {}", e),
        },
    }
}
```

#### 8. `lib/mjolnir/vsock/protocol.ex` (MODIFY)

Add network configuration message:

```elixir
def configure_network_request(ip) do
  %{
    "type" => "configure_network",
    "id" => UUID.uuid4(),
    "ip" => ip
  }
end
```

### Testing Plan

#### Unit Tests: `test/mjolnir/network_test.exs`

```elixir
describe "IP allocation" do
  test "allocates IP within configured range" do
    ip = Mjolnir.Network.allocate_ip("test-vm-123")
    assert ip =~ ~r/^10\.2\d{2}\.\d+\.\d+$/
  end

  test "generates consistent IP for same VM ID" do
    ip1 = Mjolnir.Network.allocate_ip("test-vm")
    ip2 = Mjolnir.Network.allocate_ip("test-vm")
    assert ip1 == ip2
  end

  test "different VM IDs get different IPs" do
    ip1 = Mjolnir.Network.allocate_ip("vm-a")
    ip2 = Mjolnir.Network.allocate_ip("vm-b")
    assert ip1 != ip2
  end
end

describe "MAC generation" do
  test "generates valid locally-administered MAC" do
    mac = Mjolnir.Network.generate_mac("test-vm")
    assert mac =~ ~r/^02:FC:00:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}$/i
  end

  test "generates consistent MAC for same VM ID" do
    mac1 = Mjolnir.Network.generate_mac("test-vm")
    mac2 = Mjolnir.Network.generate_mac("test-vm")
    assert mac1 == mac2
  end
end
```

#### Integration Tests: `test/mjolnir/vm_network_test.exs`

```elixir
@moduletag :integration

describe "VM networking" do
  test "VM can reach external hosts" do
    {:ok, vm} = Mjolnir.VM.spawn()
    {:ok, output} = Mjolnir.VM.exec(vm.id, "curl -s https://example.com")
    assert output =~ "Example Domain"
    Mjolnir.VM.stop(vm.id)
  end

  test "VM can resolve DNS" do
    {:ok, vm} = Mjolnir.VM.spawn()
    {:ok, output} = Mjolnir.VM.exec(vm.id, "host google.com")
    assert output =~ "has address"
    Mjolnir.VM.stop(vm.id)
  end

  test "VM has correct IP from allocation" do
    {:ok, vm} = Mjolnir.VM.spawn()
    expected_ip = Mjolnir.Network.allocate_ip(vm.id)
    {:ok, output} = Mjolnir.VM.exec(vm.id, "ip -4 addr show eth0")
    assert output =~ expected_ip
    Mjolnir.VM.stop(vm.id)
  end

  test "host has route to VM" do
    {:ok, vm} = Mjolnir.VM.spawn()
    guest_ip = vm.net_config.guest_ip
    {output, 0} = System.cmd("ip", ["route", "get", guest_ip])
    assert output =~ vm.net_config.tap_name
    Mjolnir.VM.stop(vm.id)
  end

  test "TAP and route cleaned up on VM stop" do
    {:ok, vm} = Mjolnir.VM.spawn()
    tap_name = vm.net_config.tap_name
    guest_ip = vm.net_config.guest_ip

    # TAP exists while running
    assert tap_exists?(tap_name)
    assert route_exists?(guest_ip)

    Mjolnir.VM.stop(vm.id)

    # Cleaned up after stop
    refute tap_exists?(tap_name)
    refute route_exists?(guest_ip)
  end

  defp tap_exists?(name) do
    case System.cmd("ip", ["link", "show", name], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp route_exists?(ip) do
    {output, _} = System.cmd("ip", ["route"])
    output =~ ip
  end
end
```

#### Manual Verification Checklist

- [ ] Run `sudo DEV_MODE=1 ./scripts/bootstrap-host.sh` on fresh system
- [ ] Verify iptables: `iptables -t nat -L POSTROUTING -v | grep 10.200`
- [ ] Verify forwarding: `cat /proc/sys/net/ipv4/ip_forward`
- [ ] Spawn VM: `{:ok, vm} = Mjolnir.VM.spawn()`
- [ ] Check TAP: `ip link show mj-<id>`
- [ ] Check route: `ip route | grep 10.200`
- [ ] Test connectivity: `Mjolnir.VM.exec(vm.id, "curl -I https://google.com")`
- [ ] Stop VM: `Mjolnir.VM.stop(vm.id)`
- [ ] Verify cleanup: TAP and route removed

### Debugging Guide

Add to `docs/networking-troubleshooting.md`:

```markdown
# VM Networking Troubleshooting

## Architecture Overview

Mjolnir uses flat /32 routing for VM networking:
- Range: `10.200.0.0/10` (~4 million VMs)
- Each VM gets one IP (e.g., `10.200.45.123`)
- Host adds `/32` route per VM via its TAP device
- Guest uses point-to-point link (no gateway IP)
- Host NATs traffic via iptables MASQUERADE

## Quick Checks

1. **IP forwarding enabled?**
   ```bash
   cat /proc/sys/net/ipv4/ip_forward  # Should be 1
   ```

2. **NAT rule exists?**
   ```bash
   iptables -t nat -L POSTROUTING -v | grep 10.200
   ```

3. **TAP interface exists and is up?**
   ```bash
   ip link show mj-<vm_id_prefix>
   ```

4. **Route to guest exists?**
   ```bash
   ip route | grep 10.200
   # Should show: 10.200.X.Y dev mj-XXXXXXXX scope link
   ```

5. **Guest has IP configured?**
   ```elixir
   Mjolnir.VM.exec(vm.id, "ip addr show eth0")
   Mjolnir.VM.exec(vm.id, "ip route")
   ```

## Common Issues

### "Network unreachable" in guest
- Check guest has IP: `Mjolnir.VM.exec(vm.id, "ip addr")`
- Check guest route: `Mjolnir.VM.exec(vm.id, "ip route")`
- Should show: `default dev eth0 scope link`

### "curl: (6) Could not resolve host"
- Check DNS: `Mjolnir.VM.exec(vm.id, "cat /etc/resolv.conf")`
- Test with IP: `Mjolnir.VM.exec(vm.id, "curl -I 93.184.216.34")`

### Host can't reach guest
- Check route exists: `ip route get 10.200.X.Y`
- Check TAP is up: `ip link show mj-XXXX`

### TAP creation fails
- Must run as root (or CAP_NET_ADMIN)
- Check no name collision: `ip link | grep mj-`

### Traffic not reaching internet
- Check NAT: `iptables -t nat -L -v | grep MASQUERADE`
- Check FORWARD rules: `iptables -L FORWARD -v`

## Packet Capture

```bash
# On host, capture TAP traffic for a VM
tcpdump -i mj-<vm_id_prefix> -n

# Check NAT is working (see source rewrite)
tcpdump -i eth0 -n src 10.200.0.0/10

# Watch all VM traffic
tcpdump -i any -n net 10.200.0.0/10
```

## Verify Full Path

```bash
# 1. Guest sends packet
Mjolnir.VM.exec(vm.id, "ping -c1 8.8.8.8")

# 2. Host should see it on TAP
tcpdump -i mj-XXXX -c1 icmp

# 3. Host should NAT and forward
tcpdump -i eth0 -c1 'icmp and src 10.200'  # Before NAT won't show
tcpdump -i eth0 -c1 'icmp and dst 8.8.8.8' # After NAT

# 4. Reply comes back, reverse NAT, delivered to guest
```
```

---

## Phase 2: Iroh Shell Server (Outline)

**Goal:** Interactive shell accessible via Iroh ticket

### Key Components

1. **Guest agent changes** (`native/mjolnir_guest_agent/`)
   - Add `iroh-net` dependency
   - Keypair generation/loading
   - Iroh endpoint initialization
   - PTY allocation (`nix` crate for `forkpty`)
   - Shell connection handler
   - Send `iroh_ready` via vsock

2. **Host-side changes** (`lib/mjolnir/`)
   - Handle `iroh_ready` message in vsock connection
   - Store ticket in VM state
   - Add `Mjolnir.VM.await_shell/2` API
   - Add `Mjolnir.VM.get_ticket/1` API

3. **Measure binary size impact**
   - Before: record current agent binary size
   - After: compare with iroh-net included
   - Document in plan

### Estimated Effort

High complexity due to:
- PTY handling in Rust (tricky)
- Iroh integration (new dependency)
- Async coordination (vsock + iroh)

---

## Phase 3: Client Tooling (Outline)

**Goal:** Easy-to-use CLI for shell access

### Key Components

1. **Rust CLI** (`native/mjolnir_client/` or separate repo)
   - `mjolnir connect <ticket>` - connect to shell via ticket
   - `mjolnir shell <vm-id>` - get ticket from control plane, connect
   - Terminal handling (raw mode, resize signals)

2. **Elixir integration**
   - `Mjolnir.VM.shell/1` - returns ticket or spawns client
   - WebSocket bridge for browser access (future)

3. **File transfer**
   - `mjolnir cp` command
   - Iroh blobs or simple streaming

---

## Phase 4: VM↔VM Connectivity (Outline)

**Goal:** Any VM can connect to any other VM

### Key Components

1. **Service advertisement protocol**
   - Guest agent can publish services
   - Format: `{node_id, port, name, metadata}`
   - Published via Iroh gossip or custom channel

2. **Service discovery**
   - Query by name or capability
   - Returns list of matching services

3. **Port forwarding**
   - Accept connection on node
   - Forward to local port
   - QUIC stream multiplexing

---

## Phase 5: DNS & Discovery (Outline)

**Goal:** Human-friendly addressing

### Key Components

1. **Iroh DNS integration (pkarr)**
   - Publish: `myvm.mjolnir` → node_id
   - Resolve: node_id from name

2. **Elixir cluster integration**
   - Mjolnir nodes share VM registry
   - Global VM lookup by name

---

## Implementation Order

```
Phase 1: Networking
    │
    ├── 1.1 Network module (IP allocation, MAC gen)
    ├── 1.2 TAP creation in VM spawn
    ├── 1.3 Firecracker network config
    ├── 1.4 Guest agent network setup
    ├── 1.5 Bootstrap script changes
    ├── 1.6 Integration tests
    └── 1.7 Documentation
    │
    ▼
Phase 2: Iroh Shell (depends on Phase 1)
    │
    ├── 2.1 Measure baseline binary size
    ├── 2.2 Add iroh-net to guest agent
    ├── 2.3 Keypair handling
    ├── 2.4 PTY implementation
    ├── 2.5 Shell connection handler
    ├── 2.6 Vsock iroh_ready message
    ├── 2.7 Host-side ticket caching
    └── 2.8 Integration tests
    │
    ▼
Phase 3: Client Tooling (depends on Phase 2)
    │
    ▼
Phase 4: VM↔VM (depends on Phase 2)
    │
    ▼
Phase 5: DNS (depends on Phase 4)
```

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| PTY handling in Rust is complex | High | Use well-tested `portable-pty` or `nix` crate |
| Iroh-net binary size bloat | Medium | Measure early; consider feature flags |
| Guest agent startup delay with Iroh | Medium | Initialize Iroh async; don't block vsock |
| TAP permission issues in containers | Medium | Document requirements; test in Docker |
| IP address collisions | Low | Use cryptographic hash for allocation |

---

## Success Criteria (Phase 1)

- [ ] `curl https://example.com` works from inside VM
- [ ] `apt update && apt install -y git` succeeds
- [ ] TAP interface created on spawn, deleted on stop
- [ ] No manual iptables commands needed after bootstrap
- [ ] Documentation covers troubleshooting

---

## Next Steps

1. **Review this plan** - any concerns or changes?
2. **Start Phase 1.1** - implement `Mjolnir.Network` module
3. **Iterate** - test each component before moving to next

---

*Technical plan created with SDD methodology*
