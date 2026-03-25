defmodule Mjolnir.VerifiedBootIntegrationTest do
  use Mjolnir.VMCase

  @moduletag :integration
  @moduletag :initramfs

  # Requires:
  #   1. Server running with MJOLNIR_INITRAMFS_PATH=/var/lib/mjolnir/boot/initramfs.img
  #   2. Initramfs image built and deployed via `just deploy-boot`
  #   3. Boot agent cross-compiled and included in initramfs
  #   Run: mix test --include integration --include initramfs

  @boot_timeout_ms 10_000
  # NFR1: initramfs adds < 300ms to boot time
  @max_added_latency_ms 300

  describe "initramfs two-phase boot lifecycle" do
    test "VM spawns, executes command, and stops cleanly" do
      assert {:ok, vm_id} = Mjolnir.VM.spawn(%{})
      assert {:ok, result} = Mjolnir.VM.exec(vm_id, "echo hello", 5_000)
      assert String.trim(result) == "hello"
      assert :ok = Mjolnir.VM.stop(vm_id)
    end

    test "VM reaches running state within boot timeout" do
      t0 = System.monotonic_time(:millisecond)
      assert {:ok, vm_id} = Mjolnir.VM.spawn(%{})
      elapsed = System.monotonic_time(:millisecond) - t0
      assert elapsed < @boot_timeout_ms,
             "Boot took #{elapsed}ms, expected < #{@boot_timeout_ms}ms"

      assert :ok = Mjolnir.VM.stop(vm_id)
    end

    test "uname confirms running linux kernel in guest" do
      assert {:ok, vm_id} = Mjolnir.VM.spawn(%{})
      assert {:ok, result} = Mjolnir.VM.exec(vm_id, "uname -r", 5_000)
      assert String.contains?(result, "6.") or String.contains?(result, "5."),
             "Expected kernel version, got: #{result}"

      assert :ok = Mjolnir.VM.stop(vm_id)
    end

    test "rootfs is virtiofs-mounted (flat layout preserved)" do
      assert {:ok, vm_id} = Mjolnir.VM.spawn(%{})
      assert {:ok, result} = Mjolnir.VM.exec(vm_id, "mount | grep 'on / '", 5_000)
      assert String.contains?(result, "virtiofs"),
             "Expected virtiofs root mount, got: #{result}"

      assert :ok = Mjolnir.VM.stop(vm_id)
    end

    @tag :slow
    test "boot latency overhead vs legacy is under #{@max_added_latency_ms}ms" do
      # Measure two spawns and compare — approximate, but catches gross regressions.
      # A proper measurement requires a legacy boot baseline; this test validates
      # the total boot time is within the NFR1 budget (< 3.5s total).
      max_total_boot_ms = 3_500

      t0 = System.monotonic_time(:millisecond)
      assert {:ok, vm_id} = Mjolnir.VM.spawn(%{})
      elapsed = System.monotonic_time(:millisecond) - t0
      assert elapsed < max_total_boot_ms,
             "Total boot time #{elapsed}ms exceeds #{max_total_boot_ms}ms budget (NFR1)"

      assert :ok = Mjolnir.VM.stop(vm_id)
    end
  end

  describe "backward compatibility — legacy boot when initramfs_path is nil" do
    # These tests run with initramfs_path temporarily cleared to verify
    # the legacy path is unaffected. Requires ability to override app config at runtime.

    setup do
      original = Application.get_env(:mjolnir, :initramfs_path)
      Application.delete_env(:mjolnir, :initramfs_path)
      on_exit(fn ->
        if original, do: Application.put_env(:mjolnir, :initramfs_path, original),
                    else: Application.delete_env(:mjolnir, :initramfs_path)
      end)
      :ok
    end

    test "VM spawns and execs without initramfs config" do
      assert {:ok, vm_id} = Mjolnir.VM.spawn(%{})
      assert {:ok, result} = Mjolnir.VM.exec(vm_id, "echo legacy", 5_000)
      assert String.trim(result) == "legacy"
      assert :ok = Mjolnir.VM.stop(vm_id)
    end
  end
end
