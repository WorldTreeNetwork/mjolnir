defmodule Mjolnir.Health.GuestNetwork do
  @moduledoc """
  L2 check: can the guest exec a ping, and does it come back?

  Runs `ping -c1 -W2 <gateway>` inside the guest via vsock exec. The
  gateway is the host-side IP associated with the guest's TAP. A failure
  here usually means the TAP is down, routing is wiped, or NAT is broken
  — any of which are fixable by re-running `configure_network`.
  """

  @behaviour Mjolnir.Health.Check

  require Logger

  @impl true
  def level, do: 2

  @impl true
  def name, do: "guest_network"

  @impl true
  def probe(%Mjolnir.VM{net_config: nil}), do: {:dead, :no_net_config}

  def probe(%Mjolnir.VM{} = vm) do
    # Three things matter for guest networking:
    # 1. There's a non-loopback interface (configure_network ran at boot).
    # 2. A default route exists (configure_network installed it).
    # 3. The link has carrier (host-side TAP is UP, not just the guest-side
    #    interface). Carrier drops to 0 within ~200ms of `ip link set mj-X
    #    down` on the host, which lets us detect TAP-level outages without
    #    needing a reachable host IP (Mjolnir uses /32 routes with no host-
    #    side TAP address, so there's no natural ICMP target).
    #
    # The single-exec form keeps this cheap (~100ms round-trip).
    # Default-route-presence check. This is a weak probe: it only catches
    # the case where `configure_network` never ran or got wiped. It does
    # NOT catch host-side TAP down (virtio-net doesn't propagate link
    # state to the guest) or NAT misconfiguration (route still present,
    # packets just drop). A stronger probe would ping an external target
    # via NAT, but currently Mjolnir's NAT config doesn't allow that
    # reliably on prod — see `docs/plans/durability.md` followups.
    cmd = "ip route show default 2>/dev/null | head -1"

    try do
      case Mjolnir.VM.exec(vm.id, cmd, timeout: 5_000) do
        {:ok, out} ->
          if String.contains?(out, "default") do
            :ok
          else
            {:dead, {:no_default_route, String.trim(out)}}
          end

        {:error, reason} ->
          {:dead, reason}
      end
    catch
      :exit, reason -> {:dead, {:exit, reason}}
    end
  end

  @impl true
  def heal(%Mjolnir.VM{} = vm) do
    Mjolnir.VM.reconfigure_network(vm.id)
  end
end
