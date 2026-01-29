defmodule Mjolnir.VMTest do
  use Mjolnir.VMCase

  @moduletag :integration
  @moduletag timeout: 60_000

  describe "VM.spawn/1" do
    test "spawns a VM with default settings" do
      assert {:ok, vm} = Mjolnir.VM.spawn()
      assert vm.state == :running
      assert is_binary(vm.id)

      # Cleanup
      assert :ok = Mjolnir.VM.stop(vm.id)
    end

    test "spawns a VM with custom memory" do
      assert {:ok, vm} = Mjolnir.VM.spawn(%{memory_mb: 1024})
      assert vm.config.mem_size_mib == 1024

      assert :ok = Mjolnir.VM.stop(vm.id)
    end
  end

  describe "VM.exec/2" do
    setup do
      {:ok, vm} = Mjolnir.VM.spawn()
      on_exit(fn -> Mjolnir.VM.stop(vm.id) end)
      {:ok, vm: vm}
    end

    test "executes simple command", %{vm: vm} do
      assert {:ok, output} = Mjolnir.VM.exec(vm.id, "echo hello")
      assert String.trim(output) == "hello"
    end

    test "returns kernel info", %{vm: vm} do
      assert {:ok, output} = Mjolnir.VM.exec(vm.id, "uname -a")
      assert output =~ "Linux"
    end

    test "handles command failure", %{vm: vm} do
      assert {:error, {:exit_code, code, _}} = Mjolnir.VM.exec(vm.id, "exit 42")
      assert code == 42
    end
  end

  describe "VM.stop/1" do
    test "stops a running VM" do
      {:ok, vm} = Mjolnir.VM.spawn()
      assert :running = Mjolnir.VM.status(vm.id)

      assert :ok = Mjolnir.VM.stop(vm.id)
      assert {:error, :not_found} = Mjolnir.VM.status(vm.id)
    end

    test "cleans up resources" do
      {:ok, vm} = Mjolnir.VM.spawn()
      rootfs_path = vm.rootfs_path
      socket_path = vm.socket_path

      assert File.exists?(socket_path)

      :ok = Mjolnir.VM.stop(vm.id)

      refute File.exists?(socket_path)
      refute Mjolnir.BTRFS.subvolume?(rootfs_path)
    end
  end

  describe "VM networking" do
    setup do
      {:ok, vm} = Mjolnir.VM.spawn()
      on_exit(fn -> Mjolnir.VM.stop(vm.id) end)
      {:ok, vm: vm}
    end

    test "VM has network config", %{vm: vm} do
      assert vm.net_config != nil
      assert vm.net_config.tap_name =~ ~r/^mj-/
      assert vm.net_config.guest_ip =~ ~r/^10\.\d+\.\d+\.\d+$/
      assert vm.net_config.guest_mac =~ ~r/^02:FC:00:/
    end

    test "VM has correct IP from allocation", %{vm: vm} do
      expected_ip = Mjolnir.Network.allocate_ip(vm.id)
      assert vm.net_config.guest_ip == expected_ip

      # Verify guest has this IP configured
      {:ok, output} = Mjolnir.VM.exec(vm.id, "ip -4 addr show eth0")
      assert output =~ expected_ip
    end

    test "host has route to VM", %{vm: vm} do
      guest_ip = vm.net_config.guest_ip
      {output, 0} = System.cmd("ip", ["route", "get", guest_ip])
      assert output =~ vm.net_config.tap_name
    end

    @tag :network
    test "VM can reach external hosts", %{vm: vm} do
      # This test requires host networking to be set up (iptables, ip_forward)
      {:ok, output} = Mjolnir.VM.exec(vm.id, "curl -s --max-time 10 https://example.com")
      assert output =~ "Example Domain"
    end

    @tag :network
    test "VM can resolve DNS", %{vm: vm} do
      {:ok, output} = Mjolnir.VM.exec(vm.id, "host -W 5 google.com")
      assert output =~ "has address"
    end

    test "TAP and route cleaned up on VM stop" do
      {:ok, vm} = Mjolnir.VM.spawn()
      tap_name = vm.net_config.tap_name
      guest_ip = vm.net_config.guest_ip

      # TAP exists while running
      assert tap_exists?(tap_name)
      assert route_exists?(guest_ip)

      Mjolnir.VM.stop(vm.id)

      # Give cleanup a moment
      Process.sleep(100)

      # Cleaned up after stop
      refute tap_exists?(tap_name)
      refute route_exists?(guest_ip)
    end
  end

  # Helpers

  defp tap_exists?(name) do
    case System.cmd("ip", ["link", "show", name], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp route_exists?(ip) do
    {output, _} = System.cmd("ip", ["route"])
    output =~ ip
  end
end
