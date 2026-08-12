defmodule Mjolnir.Health.GuestNetwork do
  @moduledoc """
  L2 check: does the guest have a default route, and can it reach the network?

  Runs a small shell probe inside the guest via vsock exec: it requires a
  default route, then attempts egress with whichever of curl/wget/ping the
  image actually ships. A failure here usually means the TAP is down,
  routing is wiped, or NAT is broken — any of which are fixable by
  re-running `configure_network`.

  It deliberately does NOT hard-code `ping`: that binary is absent from the
  ubuntu-24.04 base image, and the old probe read its "not found" exit as
  dead egress (mjolnir-58w). When no probe tool exists at all the result is
  `:degraded`, not `:dead` — we learned nothing, which is not the same as
  bad news.
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
    # Timeouts cap latency when the TAP is admin-down (no carrier, no outgoing
    # ARP), which would otherwise hang.
    #
    # The egress probe is tool-adaptive, and deliberately prefers TCP over ICMP:
    #
    #   * `ping` is NOT present in the ubuntu-24.04 base image (mjolnir-58w).
    #     The old probe hard-coded it, and `sh: ping: not found` is a non-zero
    #     exit indistinguishable from a dropped packet — so every VM reported
    #     `:egress_blocked` while its network was perfectly healthy.
    #   * ICMP is also the wrong signal: plenty of networks drop echo requests
    #     while carrying TCP fine. What callers actually care about is whether
    #     the guest can reach the internet.
    #
    # If no probe tool exists at all we must not claim the network is down —
    # that's the exact false-negative this replaced. Report NOTOOL instead.
    cmd = """
    ip route show default 2>/dev/null | grep -q default || { echo NOROUTE; exit 0; }
    if command -v curl >/dev/null 2>&1; then
      curl -s -o /dev/null -m 3 http://1.1.1.1/ && echo OK || echo NOEGRESS
    elif command -v wget >/dev/null 2>&1; then
      wget -q -O /dev/null -T 3 http://1.1.1.1/ && echo OK || echo NOEGRESS
    elif command -v ping >/dev/null 2>&1; then
      ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && echo OK || echo NOEGRESS
    else
      echo NOTOOL
    fi
    """

    try do
      case Mjolnir.VM.exec(vm.id, cmd, timeout: 8_000) do
        {:ok, out} ->
          case String.trim(out) do
            "OK" -> :ok
            "NOROUTE" -> {:dead, :no_default_route}
            "NOEGRESS" -> {:dead, :egress_blocked}
            # No curl/wget/ping in the guest — we learned nothing about the
            # network, so we must not report it as broken.
            "NOTOOL" -> {:degraded, :no_egress_probe_tool}
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
