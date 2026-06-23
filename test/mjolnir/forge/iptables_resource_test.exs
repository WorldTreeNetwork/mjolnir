defmodule Mjolnir.Forge.IptablesResourceTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Forge.Resource.Iptables

  setup do
    prev = Application.get_env(:mjolnir, :forge_iptables_sandbox)
    Application.put_env(:mjolnir, :forge_iptables_sandbox, true)
    Iptables.ensure_sandbox_table()

    on_exit(fn ->
      if prev,
        do: Application.put_env(:mjolnir, :forge_iptables_sandbox, prev),
        else: Application.delete_env(:mjolnir, :forge_iptables_sandbox)

      if :ets.whereis(:forge_iptables_sandbox) != :undefined do
        :ets.delete_all_objects(:forge_iptables_sandbox)
      end
    end)

    :ok
  end

  describe "kind/0" do
    test "returns \"iptables\"" do
      assert Iptables.kind() == "iptables"
    end
  end

  describe "canonical/1" do
    test "encodes table/chain header and sorted rules" do
      content = %{table: "nat", chain: "POSTROUTING", rules: ["-s 10.0.0.0/8 -j MASQUERADE"]}
      canonical = Iptables.canonical(content)
      assert canonical == "nat/POSTROUTING\n-s 10.0.0.0/8 -j MASQUERADE"
    end

    test "sorts rules for stability" do
      a = %{table: "filter", chain: "FORWARD", rules: ["-i eth0 -j ACCEPT", "-i br0 -j ACCEPT"]}
      b = %{table: "filter", chain: "FORWARD", rules: ["-i br0 -j ACCEPT", "-i eth0 -j ACCEPT"]}
      assert Iptables.canonical(a) == Iptables.canonical(b)
    end

    test "different rules produce different canonical" do
      a = %{table: "nat", chain: "POSTROUTING", rules: ["-s 10.0.0.0/8 -j MASQUERADE"]}
      b = %{table: "nat", chain: "POSTROUTING", rules: ["-s 192.168.0.0/16 -j MASQUERADE"]}
      assert Iptables.canonical(a) != Iptables.canonical(b)
    end

    test "different chains produce different canonical" do
      a = %{table: "filter", chain: "INPUT", rules: ["-j ACCEPT"]}
      b = %{table: "filter", chain: "FORWARD", rules: ["-j ACCEPT"]}
      assert Iptables.canonical(a) != Iptables.canonical(b)
    end
  end

  describe "observe_path/1" do
    test "returns :probe" do
      assert Iptables.observe_path("my-rules") == :probe
    end
  end

  describe "parse_observed/1" do
    test "parses header + rules" do
      input = "nat/POSTROUTING\n-s 10.0.0.0/8 -j MASQUERADE\n-s 172.16.0.0/12 -j MASQUERADE"
      result = Iptables.parse_observed(input)
      assert result.table == "nat"
      assert result.chain == "POSTROUTING"
      assert result.rules == ["-s 10.0.0.0/8 -j MASQUERADE", "-s 172.16.0.0/12 -j MASQUERADE"]
    end
  end

  describe "probe/2 (sandbox)" do
    test "returns :missing for unmanaged rules" do
      assert Iptables.probe("localhost", "nonexistent") == :missing
    end

    test "returns content after apply" do
      content = %{table: "nat", chain: "POSTROUTING", rules: ["-s 10.0.0.0/8 -j MASQUERADE"]}
      Iptables.apply("localhost", "my-nat", content)
      assert {:ok, ^content} = Iptables.probe("localhost", "my-nat")
    end
  end

  describe "apply/3 (sandbox)" do
    test "stores rules" do
      content = %{
        table: "filter",
        chain: "FORWARD",
        rules: ["-i mj-+ -j ACCEPT", "-o mj-+ -j ACCEPT"]
      }

      assert :ok = Iptables.apply("localhost", "vm-forward", content)
      assert {:ok, ^content} = Iptables.probe("localhost", "vm-forward")
    end

    test "apply is idempotent" do
      content = %{
        table: "nat",
        chain: "POSTROUTING",
        rules: ["-s 10.192.0.0/10 -o enp1s0 -j MASQUERADE"]
      }

      assert :ok = Iptables.apply("localhost", "nat-1", content)
      assert :ok = Iptables.apply("localhost", "nat-1", content)
      assert {:ok, ^content} = Iptables.probe("localhost", "nat-1")
    end

    test "update replaces content" do
      v1 = %{table: "filter", chain: "INPUT", rules: ["-p tcp --dport 22 -j ACCEPT"]}

      v2 = %{
        table: "filter",
        chain: "INPUT",
        rules: ["-p tcp --dport 22 -j ACCEPT", "-p tcp --dport 4000 -j ACCEPT"]
      }

      Iptables.apply("localhost", "ssh-access", v1)
      Iptables.apply("localhost", "ssh-access", v2)
      assert {:ok, ^v2} = Iptables.probe("localhost", "ssh-access")
    end
  end

  describe "delete/2 (sandbox)" do
    test "removes rules" do
      content = %{table: "nat", chain: "POSTROUTING", rules: ["-j MASQUERADE"]}
      Iptables.apply("localhost", "del-test", content)
      assert :ok = Iptables.delete("localhost", "del-test")
      assert Iptables.probe("localhost", "del-test") == :missing
    end

    test "idempotent — delete missing returns :ok" do
      assert :ok = Iptables.delete("localhost", "ghost")
    end
  end
end
