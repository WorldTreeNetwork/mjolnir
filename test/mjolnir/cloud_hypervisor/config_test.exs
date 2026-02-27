defmodule Mjolnir.CloudHypervisor.ConfigTest do
  use ExUnit.Case, async: true

  alias Mjolnir.CloudHypervisor.Config

  describe "vm_create_payload/2" do
    test "generates valid payload structure" do
      config = %Config{
        vm_id: "test-vm-id",
        kernel_path: "/path/to/vmlinux",
        rootfs_path: "/path/to/rootfs",
        virtiofsd_socket: "/tmp/test_virtiofs.sock"
      }

      payload = Config.vm_create_payload(config, "/tmp/vsock.sock")

      assert %{"payload" => _, "cpus" => _, "memory" => _, "fs" => _, "vsock" => _} = payload
      refute Map.has_key?(payload, "disks"), "disks should not be present (replaced by fs)"
      refute Map.has_key?(payload, "net"), "net should be absent when no network configured"
    end

    test "includes network config when present" do
      config = %Config{
        vm_id: "test-vm-id",
        kernel_path: "/path/to/vmlinux",
        rootfs_path: "/path/to/rootfs",
        virtiofsd_socket: "/tmp/test_virtiofs.sock",
        network_interface: %{tap_name: "mj-abc123", guest_mac: "02:FC:00:00:00:01"}
      }

      payload = Config.vm_create_payload(config, "/tmp/vsock.sock")

      assert [net_if] = payload["net"]
      assert net_if["tap"] == "mj-abc123"
      assert net_if["mac"] == "02:FC:00:00:00:01"
    end
  end

  describe "kernel_payload/1" do
    test "includes root=myfs rootfstype=virtiofs in default boot_args" do
      config = %Config{
        vm_id: "test",
        kernel_path: "/path/to/vmlinux",
        rootfs_path: "/path/to/rootfs"
      }

      payload = Config.kernel_payload(config)

      assert payload["cmdline"] =~ "root=myfs"
      assert payload["cmdline"] =~ "rootfstype=virtiofs"
      assert payload["cmdline"] =~ "rw"
      assert payload["cmdline"] =~ "console=ttyS0"
      refute payload["cmdline"] =~ "root=/dev/vda"
    end

    test "allows custom boot_args" do
      config = %Config{
        vm_id: "test",
        kernel_path: "/path/to/vmlinux",
        rootfs_path: "/path/to/rootfs",
        boot_args: "root=myfs rootfstype=virtiofs rw custom=arg"
      }

      assert Config.kernel_payload(config)["cmdline"] ==
               "root=myfs rootfstype=virtiofs rw custom=arg"
    end
  end

  describe "memory_config/1" do
    test "converts MiB to bytes with shared memory" do
      config = %Config{
        vm_id: "test",
        kernel_path: "/path",
        rootfs_path: "/path",
        mem_size_mib: 512
      }

      assert Config.memory_config(config) == %{"size" => 512 * 1024 * 1024, "shared" => true}
    end

    test "handles large memory sizes" do
      config = %Config{
        vm_id: "test",
        kernel_path: "/path",
        rootfs_path: "/path",
        mem_size_mib: 8192
      }

      result = Config.memory_config(config)
      assert result["size"] == 8_589_934_592
      assert result["shared"] == true
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

  describe "fs_config/1" do
    test "raises when virtiofsd_socket is nil" do
      config = %Config{vm_id: "test-vm", kernel_path: "/vmlinux", rootfs_path: "/rootfs"}

      assert_raise ArgumentError, ~r/virtiofsd_socket/, fn ->
        Config.fs_config(config)
      end
    end

    test "returns array with virtiofs config" do
      config = %Config{
        vm_id: "test",
        kernel_path: "/path",
        rootfs_path: "/data/vms/test-id",
        virtiofsd_socket: "/tmp/test_virtiofs.sock"
      }

      assert [
               %{
                 "tag" => "myfs",
                 "socket" => "/tmp/test_virtiofs.sock",
                 "num_queues" => 1,
                 "queue_size" => 1024
               }
             ] = Config.fs_config(config)
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
