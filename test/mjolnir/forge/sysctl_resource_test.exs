defmodule Mjolnir.Forge.SysctlResourceTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Forge.Resource.Sysctl

  setup do
    dir = Path.join(System.tmp_dir!(), "mjolnir-forge-sysctl-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # Point sysctl at our sandbox dir
    prev = Application.get_env(:mjolnir, :forge_sysctl_dir)
    Application.put_env(:mjolnir, :forge_sysctl_dir, dir)
    on_exit(fn ->
      if prev, do: Application.put_env(:mjolnir, :forge_sysctl_dir, prev),
        else: Application.delete_env(:mjolnir, :forge_sysctl_dir)
    end)

    {:ok, dir: dir}
  end

  describe "kind/0" do
    test "returns \"sysctl\"" do
      assert Sysctl.kind() == "sysctl"
    end
  end

  describe "canonical/1" do
    test "trims whitespace" do
      assert Sysctl.canonical(%{value: "1\n"}) == "1"
      assert Sysctl.canonical(%{value: "  0  "}) == "0"
    end

    test "different values produce different canonical" do
      assert Sysctl.canonical(%{value: "0"}) != Sysctl.canonical(%{value: "1"})
    end

    test "same value with different whitespace produces same canonical" do
      assert Sysctl.canonical(%{value: "1"}) == Sysctl.canonical(%{value: " 1 \n"})
    end
  end

  describe "observe_path/1" do
    test "returns :probe for all keys" do
      assert Sysctl.observe_path("net.ipv4.ip_forward") == :probe
      assert Sysctl.observe_path("vm.swappiness") == :probe
    end
  end

  describe "probe/2 (sandbox mode)" do
    test "returns :missing when no conf file exists" do
      assert Sysctl.probe("localhost", "net.core.somaxconn") == :missing
    end

    test "returns value from conf file in sandbox mode", %{dir: dir} do
      key = "net.ipv4.ip_forward"
      safe = String.replace(key, ".", "_")
      File.write!(Path.join(dir, "99-forge-#{safe}.conf"), "#{key} = 1\n")

      assert {:ok, %{value: "1"}} = Sysctl.probe("localhost", key)
    end
  end

  describe "apply/3" do
    test "writes conf file with correct format", %{dir: dir} do
      key = "net.ipv4.ip_forward"
      assert :ok = Sysctl.apply("localhost", key, %{value: "1"})

      safe = String.replace(key, ".", "_")
      path = Path.join(dir, "99-forge-#{safe}.conf")
      assert File.read!(path) == "#{key} = 1\n"
    end

    test "conf file name uses underscores for dots", %{dir: dir} do
      key = "vm.swappiness"
      assert :ok = Sysctl.apply("localhost", key, %{value: "10"})

      path = Path.join(dir, "99-forge-vm_swappiness.conf")
      assert File.exists?(path)
    end

    test "apply is idempotent", %{dir: dir} do
      key = "net.core.somaxconn"
      assert :ok = Sysctl.apply("localhost", key, %{value: "4096"})
      assert :ok = Sysctl.apply("localhost", key, %{value: "8192"})

      safe = String.replace(key, ".", "_")
      path = Path.join(dir, "99-forge-#{safe}.conf")
      assert File.read!(path) == "#{key} = 8192\n"
    end

    test "probe returns applied value", %{dir: _dir} do
      key = "kernel.pid_max"
      assert :ok = Sysctl.apply("localhost", key, %{value: "65536"})
      assert {:ok, %{value: "65536"}} = Sysctl.probe("localhost", key)
    end
  end

  describe "delete/2" do
    test "removes the conf file", %{dir: dir} do
      key = "net.ipv4.ip_forward"
      Sysctl.apply("localhost", key, %{value: "1"})

      safe = String.replace(key, ".", "_")
      path = Path.join(dir, "99-forge-#{safe}.conf")
      assert File.exists?(path)

      assert :ok = Sysctl.delete("localhost", key)
      refute File.exists?(path)
    end

    test "idempotent — delete on missing returns :ok" do
      assert :ok = Sysctl.delete("localhost", "nonexistent.param")
    end
  end
end
