defmodule Mjolnir.Forge.UfwNatResourceTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Forge.Resource.UfwNat

  setup do
    dir = Path.join(System.tmp_dir!(), "mjolnir-forge-ufw-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "before.rules")
    on_exit(fn -> File.rm_rf!(dir) end)

    prev = Application.get_env(:mjolnir, :forge_ufw_before_rules_path)
    Application.put_env(:mjolnir, :forge_ufw_before_rules_path, path)

    on_exit(fn ->
      if prev, do: Application.put_env(:mjolnir, :forge_ufw_before_rules_path, prev),
        else: Application.delete_env(:mjolnir, :forge_ufw_before_rules_path)
    end)

    {:ok, dir: dir, path: path}
  end

  describe "kind/0" do
    test "returns \"ufw_nat\"" do
      assert UfwNat.kind() == "ufw_nat"
    end
  end

  describe "canonical/1" do
    test "trims whitespace" do
      assert UfwNat.canonical(%{rules: "  *nat\nCOMMIT\n  "}) == "*nat\nCOMMIT"
    end

    test "different rules produce different canonical" do
      a = UfwNat.canonical(%{rules: "*nat\n-A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE\nCOMMIT"})
      b = UfwNat.canonical(%{rules: "*nat\n-A POSTROUTING -s 192.168.0.0/16 -j MASQUERADE\nCOMMIT"})
      assert a != b
    end
  end

  describe "observe_path/1" do
    test "returns :probe" do
      assert UfwNat.observe_path("mjolnir-nat") == :probe
    end
  end

  describe "probe/2" do
    test "returns :missing when before.rules doesn't exist" do
      assert UfwNat.probe("localhost", "my-nat") == :missing
    end

    test "returns :missing when marker block not found", %{path: path} do
      File.write!(path, """
      # some existing ufw rules
      *filter
      :INPUT ACCEPT [0:0]
      COMMIT
      """)

      assert UfwNat.probe("localhost", "my-nat") == :missing
    end

    test "extracts rules from marker block", %{path: path} do
      rules = "*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s 10.192.0.0/10 -o enp1s0 -j MASQUERADE\nCOMMIT"

      File.write!(path, """
      # ufw before rules
      *filter
      :INPUT ACCEPT [0:0]
      COMMIT
      # BEGIN FORGE-NAT: vm-nat
      #{rules}
      # END FORGE-NAT: vm-nat
      """)

      assert {:ok, %{rules: ^rules}} = UfwNat.probe("localhost", "vm-nat")
    end
  end

  describe "apply/3" do
    test "creates marker block in empty file", %{path: path} do
      rules = "*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE\nCOMMIT"
      assert :ok = UfwNat.apply("localhost", "test-nat", %{rules: rules})

      content = File.read!(path)
      assert content =~ "# BEGIN FORGE-NAT: test-nat"
      assert content =~ rules
      assert content =~ "# END FORGE-NAT: test-nat"
    end

    test "appends to existing file without clobbering", %{path: path} do
      existing = "*filter\n:INPUT ACCEPT [0:0]\nCOMMIT\n"
      File.write!(path, existing)

      rules = "*nat\n-A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE\nCOMMIT"
      assert :ok = UfwNat.apply("localhost", "my-nat", %{rules: rules})

      content = File.read!(path)
      assert content =~ "*filter"
      assert content =~ "# BEGIN FORGE-NAT: my-nat"
      assert content =~ rules
    end

    test "updates existing marker block in place", %{path: path} do
      rules_v1 = "*nat\n-A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE\nCOMMIT"
      UfwNat.apply("localhost", "nat-1", %{rules: rules_v1})

      rules_v2 = "*nat\n-A POSTROUTING -s 10.192.0.0/10 -o enp1s0 -j MASQUERADE\nCOMMIT"
      assert :ok = UfwNat.apply("localhost", "nat-1", %{rules: rules_v2})

      content = File.read!(path)
      refute content =~ "10.0.0.0/8"
      assert content =~ "10.192.0.0/10"
      # Only one begin marker
      assert length(String.split(content, "# BEGIN FORGE-NAT: nat-1")) == 2
    end

    test "multiple NAT resources coexist", %{path: path} do
      rules_a = "*nat\n-A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE\nCOMMIT"
      rules_b = "*nat\n-A PREROUTING -p tcp --dport 8080 -j DNAT --to 10.0.0.5:80\nCOMMIT"

      UfwNat.apply("localhost", "nat-egress", %{rules: rules_a})
      UfwNat.apply("localhost", "nat-ingress", %{rules: rules_b})

      content = File.read!(path)
      assert content =~ "# BEGIN FORGE-NAT: nat-egress"
      assert content =~ "# BEGIN FORGE-NAT: nat-ingress"
      assert content =~ "10.0.0.0/8"
      assert content =~ "10.0.0.5:80"
    end

    test "round-trip: apply then probe returns same rules", %{path: _path} do
      rules = "*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s 10.192.0.0/10 -o enp1s0 -j MASQUERADE\nCOMMIT"
      UfwNat.apply("localhost", "rt-test", %{rules: rules})
      assert {:ok, %{rules: ^rules}} = UfwNat.probe("localhost", "rt-test")
    end
  end

  describe "delete/2" do
    test "removes marker block from file", %{path: path} do
      rules = "*nat\n-A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE\nCOMMIT"
      UfwNat.apply("localhost", "del-nat", %{rules: rules})
      assert File.read!(path) =~ "# BEGIN FORGE-NAT: del-nat"

      assert :ok = UfwNat.delete("localhost", "del-nat")
      content = File.read!(path)
      refute content =~ "# BEGIN FORGE-NAT: del-nat"
      refute content =~ "MASQUERADE"
    end

    test "preserves other content when deleting one block", %{path: path} do
      UfwNat.apply("localhost", "keep-this", %{rules: "*nat\n-A KEEP\nCOMMIT"})
      UfwNat.apply("localhost", "remove-this", %{rules: "*nat\n-A REMOVE\nCOMMIT"})

      UfwNat.delete("localhost", "remove-this")

      content = File.read!(path)
      assert content =~ "# BEGIN FORGE-NAT: keep-this"
      assert content =~ "-A KEEP"
      refute content =~ "# BEGIN FORGE-NAT: remove-this"
      refute content =~ "-A REMOVE"
    end

    test "idempotent — delete when file missing returns :ok" do
      assert :ok = UfwNat.delete("localhost", "nonexistent")
    end
  end
end
