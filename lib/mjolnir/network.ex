defmodule Mjolnir.Network do
  @moduledoc """
  TAP interface management for VM networking.

  Uses flat /32 routing: each VM gets a single IP, host adds a route via TAP.
  Host provides NAT via iptables MASQUERADE.

  Default range: 10.200.0.0/10 (~4 million VMs)

  ## Architecture

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
      └─────────────────────────────────────────────────────────────┘
               │               │               │
          ┌────┴────┐     ┌────┴────┐     ┌────┴────┐
          │ VM 1    │     │ VM 2    │     │ VM N    │
          │10.200.  │     │10.200.  │     │10.200.  │
          │  0.2/32 │     │  0.3/32 │     │  X.Y/32 │
          │ p2p link│     │ p2p link│     │ p2p link│
          └─────────┘     └─────────┘     └─────────┘
  """

  require Logger

  @default_subnet "10.200.0.0/10"

  @type net_config :: %{
          tap_name: String.t(),
          guest_ip: String.t(),
          guest_mac: String.t()
        }

  @doc """
  Create and configure a TAP interface for a VM.

  1. Creates TAP device (no IP on host side)
  2. Allocates guest IP from pool
  3. Adds /32 route to guest via TAP
  4. Returns config for the hypervisor + guest agent

  Returns `{:ok, %{tap_name: String.t(), guest_ip: String.t(), guest_mac: String.t()}}`
  """
  @spec create_tap(String.t()) :: {:ok, net_config()} | {:error, term()}
  def create_tap(vm_id) do
    tap_name = tap_name(vm_id)
    guest_ip = allocate_ip(vm_id)
    guest_mac = generate_mac(vm_id)

    with :ok <- create_tap_device(tap_name),
         :ok <- bring_tap_up(tap_name),
         :ok <- enable_proxy_arp(tap_name),
         :ok <- add_route(guest_ip, tap_name) do
      Logger.info("Created TAP #{tap_name} for VM #{short_id(vm_id)} with IP #{guest_ip}")

      {:ok,
       %{
         tap_name: tap_name,
         guest_ip: guest_ip,
         guest_mac: guest_mac
       }}
    else
      {:error, reason} = err ->
        Logger.error("Failed to create TAP for #{vm_id}: #{inspect(reason)}")
        # Attempt cleanup
        _ = delete_tap(tap_name, guest_ip)
        err
    end
  end

  @doc """
  Delete a TAP interface and remove its route.
  """
  @spec delete_tap(String.t(), String.t()) :: :ok
  def delete_tap(tap_name, guest_ip) do
    # Remove route first (may fail if tap is already gone, that's fine)
    _ = run_cmd("ip", ["route", "del", "#{guest_ip}/32", "dev", tap_name])

    # Delete TAP device
    case run_cmd("ip", ["link", "del", tap_name]) do
      :ok ->
        Logger.debug("Deleted TAP #{tap_name}")
        :ok

      {:error, _} ->
        # Probably already gone
        :ok
    end
  end

  @doc """
  Generate a deterministic MAC address from VM ID.
  Format: 02:FC:00:xx:xx:xx (locally administered)

  The first byte 02 indicates:
  - Bit 0 = 0: unicast
  - Bit 1 = 1: locally administered (not globally unique)
  """
  @spec generate_mac(String.t()) :: String.t()
  def generate_mac(vm_id) do
    # Hash the VM ID and take 3 bytes for the last 3 octets
    <<b1, b2, b3, _rest::binary>> = :crypto.hash(:sha256, vm_id)

    # Format: 02:FC:00:xx:xx:xx
    "02:FC:00:#{hex(b1)}:#{hex(b2)}:#{hex(b3)}"
  end

  @doc """
  Allocate an IP address for a VM based on its ID.
  Uses consistent hashing to map VM ID to IP in configured range.
  Returns guest_ip as string (e.g., "10.200.45.123")

  The 10.200.0.0/10 range spans:
  - 10.192.0.0 to 10.255.255.255 (4,194,304 addresses)

  We skip .0 and .255 in the last octet to avoid broadcast confusion.
  """
  @spec allocate_ip(String.t()) :: String.t()
  def allocate_ip(vm_id) do
    # Hash VM ID to get deterministic bytes
    <<hash::unsigned-32, _rest::binary>> = :crypto.hash(:sha256, vm_id)

    # 10.200.0.0/10 = 10.192.0.0 - 10.255.255.255
    # That's 64 * 256 * 256 = 4,194,304 addresses
    # Base: 10.192.0.0 = (10 << 24) | (192 << 16) = 180_355_072
    base = 10 * 256 * 256 * 256 + 192 * 256 * 256
    range_size = 64 * 256 * 256

    # Map hash to range, avoiding .0 and .255 in last octet
    offset = rem(hash, range_size)
    ip_int = base + offset

    # Extract octets
    o1 = div(ip_int, 256 * 256 * 256)
    o2 = rem(div(ip_int, 256 * 256), 256)
    o3 = rem(div(ip_int, 256), 256)
    o4 = rem(ip_int, 256)

    # Avoid .0 and .255 - shift to .1 or .254
    o4 =
      cond do
        o4 == 0 -> 1
        o4 == 255 -> 254
        true -> o4
      end

    "#{o1}.#{o2}.#{o3}.#{o4}"
  end

  @doc """
  Generate TAP device name from VM ID.
  Format: mj-{first 8 chars of vm_id}
  """
  @spec tap_name(String.t()) :: String.t()
  def tap_name(vm_id) do
    "mj-#{short_id(vm_id)}"
  end

  @doc """
  Get the configured VM network range.
  Default: "10.200.0.0/10"
  """
  @spec network_range() :: String.t()
  def network_range do
    Application.get_env(:mjolnir, :vm_network, [])
    |> Keyword.get(:subnet, @default_subnet)
  end

  # Private helpers

  defp short_id(vm_id), do: String.slice(vm_id, 0, 8)

  defp hex(byte), do: String.downcase(Base.encode16(<<byte>>))

  defp create_tap_device(tap_name) do
    run_cmd("ip", ["tuntap", "add", tap_name, "mode", "tap"])
  end

  defp bring_tap_up(tap_name) do
    run_cmd("ip", ["link", "set", tap_name, "up"])
  end

  defp enable_proxy_arp(tap_name) do
    # Proxy ARP makes the host respond to ARP requests for any IP on behalf of the guest
    # Required for point-to-point /32 routing where guest ARPs for destination directly
    path = "/proc/sys/net/ipv4/conf/#{tap_name}/proxy_arp"
    File.write(path, "1")
  end

  defp add_route(guest_ip, tap_name) do
    run_cmd("ip", ["route", "add", "#{guest_ip}/32", "dev", tap_name])
  end

  defp run_cmd(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, code} ->
        {:error, {:cmd_failed, cmd, args, code, output}}
    end
  end
end
