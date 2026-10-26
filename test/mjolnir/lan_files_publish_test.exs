defmodule Mjolnir.LanFilesPublishTest do
  use ExUnit.Case, async: true
  alias Mjolnir.{LanFiles, Network}

  defp config, do: %{vm_id: "share", interface: "enp3s0", publish_port: 7443, http_port: 8080}
  defp vm(ip \\ "10.200.0.9"), do: %{id: "share", state: :running, net_config: %{tap_name: "mj-share", guest_ip: ip}}
  defp rules(ip \\ "10.200.0.9"), do: LanFiles.desired(vm(ip), config(), fn "enp3s0" -> {:ok, "192.168.0.10"} end)

  # Stateful fake implements -C/-I/-D and records every command; never invokes iptables.
  defp runner do
    {:ok, store} = Agent.start_link(fn -> {MapSet.new(), []} end)
    run = fn ["-t", table, op, chain | rest] = args ->
      spec = if op == "-I", do: tl(rest), else: rest
      key = {table, chain, spec}
      Agent.get_and_update(store, fn {installed, calls} ->
        {reply, next} = case op do
          "-C" -> {{"", if(MapSet.member?(installed, key), do: 0, else: 1)}, installed}
          "-I" -> {{"", 0}, MapSet.put(installed, key)}
          "-D" -> {{"", 0}, MapSet.delete(installed, key)}
        end
        {reply, {next, calls ++ [args]}}
      end)
    end
    {store, run}
  end

  test "DNAT matches named ingress, exact current destination and non-door port" do
    [{"filter", "FORWARD", forward}, {"filter", "FORWARD", reply}, {"nat", "PREROUTING", dnat}] = rules()
    assert Enum.take(dnat, 8) == ["-i", "enp3s0", "-d", "192.168.0.10/32", "-p", "tcp", "--dport", "7443"]
    assert Enum.take(dnat, -4) == ["-j", "DNAT", "--to-destination", "10.200.0.9:8080"]
    refute "7222" in dnat
    assert Enum.take(forward, 10) == ["-i", "enp3s0", "-o", "mj-share", "-p", "tcp", "-d", "10.200.0.9", "--dport", "8080"]
    assert ["--ctorigdst", "192.168.0.10", "--ctorigdstport", "7443"] == Enum.slice(reply, 16, 4)
    assert "REPLY" in reply
    assert "ESTABLISHED" in reply
    # A different ingress or destination cannot match this exact -i/-d pair.
    refute "wlan0" in dnat
    refute "192.168.0.11/32" in dnat
  end

  test "idempotent setup, replacement, stop, and address disappearance" do
    {store, run} = runner()
    assert {:ok, owned} = LanFiles.reconcile([], rules(), run)
    assert {:ok, ^owned} = LanFiles.reconcile(owned, rules(), run)
    {installed, calls} = Agent.get(store, & &1)
    assert MapSet.size(installed) == 3
    assert Enum.count(calls, &(Enum.at(&1, 2) == "-I")) == 3
    assert {:ok, new} = LanFiles.reconcile(owned, rules("10.200.0.12"), run)
    {installed, calls} = Agent.get(store, & &1)
    assert installed == MapSet.new(new)
    mutations = Enum.filter(calls, &(Enum.at(&1, 2) in ["-I", "-D"]))
    assert Enum.map(Enum.slice(mutations, 3, 6), &Enum.at(&1, 2)) == ["-D", "-D", "-D", "-I", "-I", "-I"]
    assert {:ok, []} = LanFiles.reconcile(new, [], run)
    assert Agent.get(store, fn {installed, _} -> MapSet.size(installed) end) == 0
    assert LanFiles.desired(%{vm() | state: :stopped}, config()) == []
    assert LanFiles.desired(vm(), config(), fn _ -> {:error, :no_ipv4_address} end) == []
    assert LanFiles.desired(%{vm() | id: "other"}, config()) == []
  end

  test "address change replaces exact destination; absent address never adds rules" do
    {store, run} = runner()
    assert {:ok, old} = LanFiles.reconcile([], rules(), run)
    new = LanFiles.desired(vm(), config(), fn _ -> {:ok, "192.168.0.20"} end)
    assert {:ok, ^new} = LanFiles.reconcile(old, new, run)
    missing = LanFiles.desired(vm(), config(), fn _ -> {:error, :no_ipv4_address} end)
    assert {:ok, []} = LanFiles.reconcile(new, missing, run)
    assert Agent.get(store, fn {installed, _} -> MapSet.size(installed) end) == 0
    assert {:error, :no_ipv4_address} = LanFiles.interface_ipv4("mjolnir-nonexistent-test-interface")
    for address <- ["0.0.0.0", "::", "2001:db8::1"] do
      assert_raise ArgumentError, fn -> Network.lan_files_rules("eth0", address, 7443, "tap0", "10.200.0.9", 8080) end
    end
    assert_raise ArgumentError, fn -> Network.lan_files_rules("eth0", "192.168.0.10", 7222, "tap0", "10.200.0.9", 8080) end
  end

  test "failed cleanup blocks installing the replacement" do
    parent = self()
    run = fn args -> send(parent, {:command, args}); {"permission denied", 2} end
    old = rules()
    assert {:error, _, ^old} = LanFiles.reconcile(old, rules("10.200.0.12"), run)
    refute_received {:command, ["-t", _, "-I" | _]}
  end
end
