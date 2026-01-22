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
end
