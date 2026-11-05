defmodule Mjolnir.Health.GuestNetwork do
  @moduledoc """
  L2 network check. Ordinary guests require public egress; proxy images require
  an intact isolated host route and a TCP connection to the host API.
  Healing runs the image's own network setup through the guest agent.
  """

  @behaviour Mjolnir.Health.Check

  @impl true
  def level, do: 2

  @impl true
  def name, do: "guest_network"

  @impl true
  def probe(%Mjolnir.VM{net_config: nil}), do: {:dead, :no_net_config}

  def probe(%Mjolnir.VM{} = vm) do
    class = Mjolnir.ProxyGuest.image_class(vm.config[:base_image])
    cmd = command(class)

    try do
      case Mjolnir.VM.exec(vm.id, cmd, timeout: 8_000) do
        {:ok, out} -> classify(class, out)
        {:error, reason} -> {:dead, reason}
      end
    catch
      :exit, reason -> {:dead, {:exit, reason}}
    end
  end

  @doc false
  def command(:ordinary) do
    """
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
  end

  @doc false
  def command(:proxy) do
    """
    routes=$(ip -4 route show 2>/dev/null) || { echo INSPECTFAIL; exit 0; }
    printf '%s\n' "$routes" | sed '/^$/d; s/^/ROUTE /'
    awk '$1 == "nameserver" {print "DNS " $2}' /etc/resolv.conf || { echo INSPECTFAIL; exit 0; }
    if command -v bash >/dev/null 2>&1; then
      timeout 3 bash -c 'exec 3<>/dev/tcp/10.200.0.1/4000' >/dev/null 2>&1 && echo OK || echo NOEGRESS
    else
      echo NOTOOL
    fi
    """
  end

  @doc "Pure interpretation of guest inspection; no VM or socket calls."
  def classify(:ordinary, out) do
    case String.trim(out) do
      "OK" -> :ok
      "NOROUTE" -> {:dead, :no_default_route}
      "NOEGRESS" -> {:dead, :egress_blocked}
      "NOTOOL" -> {:degraded, :no_egress_probe_tool}
      other -> {:dead, {:unexpected_probe_output, other}}
    end
  end

  def classify(:proxy, out) do
    lines = String.split(String.trim(out), "\n", trim: true)
    routes = for "ROUTE " <> route <- lines, do: String.split(route)
    resolvers = for "DNS " <> resolver <- lines, do: resolver

    cond do
      "INSPECTFAIL" in lines ->
        {:dead, :network_inspection_failed}

      Enum.any?(routes, &match?(["default" | _], &1)) ->
        {:dead, :proxy_default_route}

      resolvers != ["127.0.0.1"] ->
        {:dead, :proxy_resolver_drift}

      not Enum.any?(routes, fn
        [host | _] -> host in ["10.200.0.1", "10.200.0.1/32"]
        _ -> false
      end) ->
        {:dead, :proxy_host_route_missing}

      List.last(lines) == "NOTOOL" ->
        {:degraded, :no_egress_probe_tool}

      List.last(lines) == "NOEGRESS" ->
        {:dead, :egress_blocked}

      List.last(lines) == "OK" ->
        :ok

      true ->
        {:dead, {:unexpected_probe_output, out}}
    end
  end

  @impl true
  def heal(%Mjolnir.VM{} = vm) do
    Mjolnir.VM.reconfigure_network(vm.id)
  end
end
