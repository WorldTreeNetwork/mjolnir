defmodule Mjolnir.CloudHypervisor.ConfigTest do
  use ExUnit.Case, async: true

  alias Mjolnir.CloudHypervisor.Config

  describe "vm_create_payload/2" do
    test "generates valid payload structure" do
      config = %Config{
        vm_id: "test-vm-id",
        kernel_path: "/path/to/vmlinux",
        rootfs_path: "/path/to/rootfs.ext4"
      }

      payload = Config.vm_create_payload(config, "/tmp/vsock.sock")

      assert %{"payload" => _, "cpus" => _, "memory" => _, "disks" => _, "vsock" => _} = payload
      refute Map.has_key?(payload, "net"), "net should be absent when no network configured"
    end

    test "includes network config when present" do
      config = %Config{
        vm_id: "test-vm-id",
        kernel_path: "/path/to/vmlinux",
        rootfs_path: "/path/to/rootfs.ext4",
        network_interface: %{tap_name: "mj-abc123", guest_mac: "02:FC:00:00:00:01"}
      }

      payload = Config.vm_create_payload(config, "/tmp/vsock.sock")

      assert [net_if] = payload["net"]
      assert net_if["tap"] == "mj-abc123"
      assert net_if["mac"] == "02:FC:00:00:00:01"
    end
  end

  describe "kernel_payload/1" do
    test "includes root=/dev/vda rw in default boot_args" do
      config = %Config{
        vm_id: "test",
        kernel_path: "/path/to/vmlinux",
        rootfs_path: "/path/to/rootfs.ext4"
      }

      payload = Config.kernel_payload(config)

      assert payload["cmdline"] =~ "root=/dev/vda"
      assert payload["cmdline"] =~ "rw"
      assert payload["cmdline"] =~ "console=ttyS0"
    end

    test "allows custom boot_args" do
      config = %Config{
        vm_id: "test",
        kernel_path: "/path/to/vmlinux",
        rootfs_path: "/path/to/rootfs.ext4",
        boot_args: "custom=args root=/dev/vda rw"
      }

      assert Config.kernel_payload(config)["cmdline"] == "custom=args root=/dev/vda rw"
    end
  end

  describe "memory_config/1" do
    test "converts MiB to bytes" do
      config = %Config{
        vm_id: "test",
        kernel_path: "/path",
        rootfs_path: "/path",
        mem_size_mib: 512
      }

      assert Config.memory_config(config) == %{"size" => 512 * 1024 * 1024}
    end

    test "handles large memory sizes" do
      config = %Config{
        vm_id: "test",
        kernel_path: "/path",
        rootfs_path: "/path",
        mem_size_mib: 8192
      }

      assert Config.memory_config(config)["size"] == 8_589_934_592
    end
  end

  describe "vsock_config/2" do
    test "sets CID and socket path" do
      config = %Config{
        vm_id: "test",
        kernel_path: "/path",
        rootfs_path: "/path",
        vsock_cid: 42
      }

      result = Config.vsock_config(config, "/tmp/test_vsock")

      assert result == %{"cid" => 42, "socket" => "/tmp/test_vsock"}
    end

    test "default CID is 3" do
      config = %Config{vm_id: "test", kernel_path: "/path", rootfs_path: "/path"}
      assert config.vsock_cid == 3
    end
  end

  describe "cpus_config/1" do
    test "sets boot and max vcpus equally" do
      config = %Config{
        vm_id: "test",
        kernel_path: "/path",
        rootfs_path: "/path",
        vcpu_count: 4
      }

      assert Config.cpus_config(config) == %{"boot_vcpus" => 4, "max_vcpus" => 4}
    end
  end

  describe "disks_config/1" do
    test "returns array with rootfs path" do
      config = %Config{
        vm_id: "test",
        kernel_path: "/path",
        rootfs_path: "/data/vms/rootfs.ext4"
      }

      assert [%{"path" => "/data/vms/rootfs.ext4"}] = Config.disks_config(config)
    end
  end

  describe "network_config/1" do
    test "returns nil when no network interface" do
      config = %Config{vm_id: "test", kernel_path: "/path", rootfs_path: "/path"}
      assert Config.network_config(config) == nil
    end

    test "returns tap and mac config" do
      config = %Config{
        vm_id: "test",
        kernel_path: "/path",
        rootfs_path: "/path",
        network_interface: %{tap_name: "mj-test", guest_mac: "02:FC:00:00:00:FF"}
      }

      assert [%{"tap" => "mj-test", "mac" => "02:FC:00:00:00:FF"}] =
               Config.network_config(config)
    end
  end
end
