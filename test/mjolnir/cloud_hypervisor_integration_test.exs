defmodule Mjolnir.CloudHypervisorIntegrationTest do
  @moduledoc """
  Integration tests specific to Cloud Hypervisor as the default hypervisor.
  Requires KVM, root access, and Cloud Hypervisor binary installed.
  """
  use Mjolnir.VMCase

  @moduletag :integration
  @moduletag :cloud_hypervisor
  @moduletag timeout: 120_000

  describe "CH VM lifecycle" do
    test "spawns VM using Cloud Hypervisor" do
      {:ok, vm} = Mjolnir.VM.spawn()

      assert vm.state == :running
      assert vm.hypervisor == Mjolnir.Hypervisor.CloudHypervisor

      :ok = Mjolnir.VM.stop(vm.id)
    end

    test "VM boots with correct root filesystem" do
      {:ok, vm} = Mjolnir.VM.spawn()
      on_exit(fn -> Mjolnir.VM.stop(vm.id) end)

      # Verify root is mounted rw (the boot_args fix)
      {:ok, output} = Mjolnir.VM.exec(vm.id, "mount | grep 'on / '")
      assert output =~ "rw", "Root filesystem should be mounted read-write"
    end

    test "VM has unique vsock CID" do
      {:ok, vm1} = Mjolnir.VM.spawn()
      {:ok, vm2} = Mjolnir.VM.spawn()

      on_exit(fn ->
        Mjolnir.VM.stop(vm1.id)
        Mjolnir.VM.stop(vm2.id)
      end)

      # Both VMs should be running (no CID collision)
      assert vm1.state == :running
      assert vm2.state == :running

      # Verify both can execute commands independently
      {:ok, out1} = Mjolnir.VM.exec(vm1.id, "echo vm1")
      {:ok, out2} = Mjolnir.VM.exec(vm2.id, "echo vm2")
      assert String.trim(out1) == "vm1"
      assert String.trim(out2) == "vm2"
    end

    test "boot_time is a valid Unix timestamp" do
      {:ok, vm} = Mjolnir.VM.spawn()
      on_exit(fn -> Mjolnir.VM.stop(vm.id) end)

      # boot_time should be a recent Unix timestamp in milliseconds
      now_ms = System.system_time(:millisecond)
      assert vm.boot_time > 0, "boot_time should be positive (not monotonic)"
      assert vm.boot_time <= now_ms, "boot_time should not be in the future"
      # Boot should have happened within the last 60 seconds
      assert now_ms - vm.boot_time < 60_000, "boot_time should be recent"
    end
  end

  describe "CH cleanup on failure" do
    test "cleanup doesn't crash on missing resources" do
      # Simulate calling cleanup with minimal state
      state = %{
        id: "nonexistent-#{UUID.uuid4()}",
        hypervisor_port: nil,
        net_config: nil,
        rootfs_path: nil,
        vsock_conn: nil,
        socket_path: nil,
        vsock_path: nil
      }

      assert :ok = Mjolnir.Hypervisor.CloudHypervisor.cleanup(state)
    end
  end

  describe "concurrent VM spawning" do
    @tag timeout: 180_000
    test "can spawn 3 VMs concurrently" do
      tasks =
        for _ <- 1..3 do
          Task.async(fn -> Mjolnir.VM.spawn() end)
        end

      results = Task.await_many(tasks, 60_000)

      vms =
        Enum.map(results, fn
          {:ok, vm} -> vm
          other -> flunk("Expected {:ok, vm}, got: #{inspect(other)}")
        end)

      on_exit(fn ->
        Enum.each(vms, fn vm -> Mjolnir.VM.stop(vm.id) end)
      end)

      # All running
      assert Enum.all?(vms, &(&1.state == :running))

      # All have unique IDs
      ids = Enum.map(vms, & &1.id)
      assert length(Enum.uniq(ids)) == 3

      # All have unique IPs
      ips = Enum.map(vms, & &1.net_config.guest_ip)
      assert length(Enum.uniq(ips)) == 3

      # All respond independently
      for vm <- vms do
        {:ok, out} = Mjolnir.VM.exec(vm.id, "hostname")
        assert is_binary(out)
      end
    end
  end
end
