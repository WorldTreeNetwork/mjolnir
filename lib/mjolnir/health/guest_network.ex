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
    # Two-phase probe, one shell round-trip:
    #
    # 1. Default route exists? Fast check for "configure_network never ran /
    #    got wiped inside the guest" — doesn't exercise the TAP or NAT.
    # 2. Ping 1.1.1.1 with -W2? This exercises the host-side TAP link, the
    #    /32 route on the host, and the MASQUERADE rule all together. It's
    #    the load-bearing check: if any of those are broken, this fails.
    #
    # Echoing a token string per branch keeps parsing exit-code-independent.
    # 2s ping timeout caps latency when TAP is admin-down (no carrier, no
    # outgoing ARP), which would otherwise hang.
    cmd = """
    ip route show default 2>/dev/null | grep -q default || { echo NOROUTE; exit 0; }
    ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 || { echo NOPING; exit 0; }
    echo OK
    """

    try do
      case Mjolnir.VM.exec(vm.id, cmd, timeout: 8_000) do
        {:ok, out} ->
          case String.trim(out) do
            "OK" -> :ok
            "NOROUTE" -> {:dead, :no_default_route}
            "NOPING" -> {:dead, :egress_blocked}
            other -> {:dead, {:unexpected_probe_output, other}}
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
