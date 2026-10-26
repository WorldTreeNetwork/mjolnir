defmodule Mjolnir.LanFiles do
  @moduledoc """
  IPv4 publication owned by the share VM's host GenServer.

  Configure `:mjolnir, :lan_files` with `vm_id`, `interface`, `publish_port`
  and `http_port`. The guest binary must already be running at its TAP IP.
  Only the explicitly selected VM publishes. Reconciliation removes the old
  flow before adding its replacement and never substitutes a missing address.
  """

  def desired(vm, config, address_lookup \\ &interface_ipv4/1)
  def desired(_vm, nil, _lookup), do: []

  def desired(%{id: id, state: :running, net_config: net}, %{vm_id: id} = config, lookup)
      when is_map(net) do
    with {:ok, address} <- lookup.(config.interface) do
      Mjolnir.Network.lan_files_rules(
        config.interface, address, config.publish_port,
        net.tap_name, net.guest_ip, config.http_port
      )
    else
      _ -> []
    end
  end

  def desired(_vm, _config, _lookup), do: []

  def interface_ipv4(interface) do
    with {:ok, interfaces} <- :inet.getifaddrs(),
         {_, attrs} <- List.keyfind(interfaces, String.to_charlist(interface), 0),
         {a, _, _, _} = ip <- Enum.find_value(attrs, fn
           {:addr, {_, _, _, _} = ip} -> ip
           _ -> nil
         end),
         true <- a != 0 and a != 127 do
      {:ok, :inet.ntoa(ip) |> to_string()}
    else
      _ -> {:error, :no_ipv4_address}
    end
  end

  @doc "Reconcile explicit rules; the returned owned set includes any failed cleanup."
  def reconcile(owned, desired, run \\ &iptables/1) do
    {remaining, errors} =
      Enum.reduce(Enum.reverse(owned -- desired), {owned, []}, fn rule, {current, errors} ->
        case remove(rule, run) do
          :ok -> {List.delete(current, rule), errors}
          error -> {current, [error | errors]}
        end
      end)

    # Never publish a new target until all old rules have been removed.
    if errors != [] do
      {:error, errors, remaining}
    else
      Enum.reduce_while(desired, {:ok, remaining}, fn rule, {:ok, current} ->
        case ensure(rule, run) do
          :ok -> {:cont, {:ok, Enum.uniq(current ++ [rule])}}
          error ->
            # Also clean up partially installed flows on the next pass.
            {:halt, {:error, error, Enum.uniq(current ++ [rule])}}
        end
      end)
    end
  end

  defp ensure({table, chain, spec}, run) do
    case run.(["-t", table, "-C", chain | spec]) do
      {_, 0} -> :ok
      {_, 1} -> result(run.(["-t", table, "-I", chain, "1" | spec]))
      error -> {:error, error}
    end
  end

  defp remove({table, chain, spec}, run) do
    case run.(["-t", table, "-C", chain | spec]) do
      {_, 0} -> result(run.(["-t", table, "-D", chain | spec]))
      {_, 1} -> :ok
      error -> {:error, error}
    end
  end

  defp result({_, 0}), do: :ok
  defp result(error), do: {:error, error}
  defp iptables(args), do: System.cmd("sudo", ["-n", "iptables", "-w", "5" | args], stderr_to_stdout: true)
end
