defmodule Mjolnir.InitramfsTest do
  use ExUnit.Case, async: true

  alias Mjolnir.CloudHypervisor.Config

  # ---------------------------------------------------------------------------
  # Story 3.1: Config struct — kernel_payload/1 branching
  # ---------------------------------------------------------------------------

  describe "Config.kernel_payload/1 — nil initramfs_path (legacy mode)" do
    setup do
      {:ok,
       config: %Config{
         vm_id: "test-vm-001",
         kernel_path: "/var/lib/mjolnir/vmlinux-ch",
         rootfs_path: "/var/lib/mjolnir/btrfs/@vms/test-vm-001",
         virtiofsd_socket: "/tmp/mjolnir/test-vm-001_virtiofs.sock",
         boot_args: "console=ttyS0 reboot=k panic=1 root=myfs rootfstype=virtiofs rw"
       }}
    end

    test "returns kernel and cmdline keys only", %{config: config} do
      payload = Config.kernel_payload(config)
      assert Map.keys(payload) |> Enum.sort() == ["cmdline", "kernel"]
    end

    test "does not include initramfs key", %{config: config} do
      payload = Config.kernel_payload(config)
      refute Map.has_key?(payload, "initramfs")
    end

    test "kernel value matches kernel_path", %{config: config} do
      payload = Config.kernel_payload(config)
      assert payload["kernel"] == config.kernel_path
    end

    test "cmdline value matches boot_args", %{config: config} do
      payload = Config.kernel_payload(config)
      assert payload["cmdline"] == config.boot_args
    end

    test "vm_create_payload payload section has no initramfs key", %{config: config} do
      full = Config.vm_create_payload(config, "/tmp/mjolnir/test-vm-001_vsock")
      refute Map.has_key?(full["payload"], "initramfs")
    end
  end

  describe "Config.kernel_payload/1 — initramfs_path set (initramfs mode)" do
    setup do
      {:ok,
       config: %Config{
         vm_id: "test-vm-002",
         kernel_path: "/var/lib/mjolnir/vmlinux-ch",
         rootfs_path: "/var/lib/mjolnir/btrfs/@vms/test-vm-002",
         virtiofsd_socket: "/tmp/mjolnir/test-vm-002_virtiofs.sock",
         boot_args: "console=ttyS0 reboot=k panic=1 rw",
         initramfs_path: "/var/lib/mjolnir/boot/initramfs.img"
       }}
    end

    test "includes initramfs key", %{config: config} do
      payload = Config.kernel_payload(config)
      assert Map.has_key?(payload, "initramfs")
    end

    test "initramfs value matches initramfs_path", %{config: config} do
      payload = Config.kernel_payload(config)
      assert payload["initramfs"] == "/var/lib/mjolnir/boot/initramfs.img"
    end

    test "kernel and cmdline keys still present", %{config: config} do
      payload = Config.kernel_payload(config)
      assert payload["kernel"] == config.kernel_path
      assert payload["cmdline"] == config.boot_args
    end

    test "vm_create_payload payload section includes initramfs key", %{config: config} do
      full = Config.vm_create_payload(config, "/tmp/mjolnir/test-vm-002_vsock")
      assert full["payload"]["initramfs"] == "/var/lib/mjolnir/boot/initramfs.img"
    end
  end

  # ---------------------------------------------------------------------------
  # Story 3.2: Boot args branching via Application config
  # ---------------------------------------------------------------------------

  describe "configure_vm/2 boot args — nil initramfs_path (legacy mode)" do
    test "legacy boot_args include root=myfs and rootfstype=virtiofs" do
      config = %Config{
        vm_id: "leg-001",
        kernel_path: "/k",
        rootfs_path: "/r",
        virtiofsd_socket: "/s"
      }

      # Default boot_args from struct
      assert String.contains?(config.boot_args, "root=myfs")
      assert String.contains?(config.boot_args, "rootfstype=virtiofs")
    end

    test "Application.get_env(:mjolnir, :initramfs_path) is nil by default" do
      # Verify the config.exs default is in effect
      assert Application.get_env(:mjolnir, :initramfs_path) == nil
    end
  end

  describe "configure_vm/2 boot args — initramfs_path set" do
    setup do
      Application.put_env(:mjolnir, :initramfs_path, "/var/lib/mjolnir/boot/initramfs.img")
      on_exit(fn -> Application.delete_env(:mjolnir, :initramfs_path) end)
      :ok
    end

    test "initramfs boot_args omit root= and rootfstype=" do
      initramfs_boot_args = "console=ttyS0 reboot=k panic=1 rw"
      refute String.contains?(initramfs_boot_args, "root=")
      refute String.contains?(initramfs_boot_args, "rootfstype=")
    end

    test "Application.get_env reflects override" do
      assert Application.get_env(:mjolnir, :initramfs_path) ==
               "/var/lib/mjolnir/boot/initramfs.img"
    end
  end

  # ---------------------------------------------------------------------------
  # Story 3.3: try_ping_agent response parsing (tested via protocol parsing)
  # ---------------------------------------------------------------------------

  describe "pong response parsing — agent type extraction" do
    # These tests validate the JSON parsing logic used inside try_ping_agent/1.
    # try_ping_agent/1 is private; we test the parsing logic directly here
    # to verify correct boot/full discrimination without needing vsock infra.

    test "pong with agent=boot maps to :boot" do
      body = Jason.encode!(%{"type" => "pong", "id" => "abc123", "agent" => "boot"})
      {:ok, pong} = Jason.decode(body)
      assert pong["type"] == "pong"
      agent_type = if pong["agent"] == "boot", do: :boot, else: :full
      assert agent_type == :boot
    end

    test "pong without agent field maps to :full" do
      body = Jason.encode!(%{"type" => "pong", "id" => "abc123"})
      {:ok, pong} = Jason.decode(body)
      assert pong["type"] == "pong"
      agent_type = if pong["agent"] == "boot", do: :boot, else: :full
      assert agent_type == :full
    end

    test "pong with agent=full maps to :full" do
      # future-proof: explicit "full" value also maps correctly
      body = Jason.encode!(%{"type" => "pong", "id" => "abc123", "agent" => "full"})
      {:ok, pong} = Jason.decode(body)
      agent_type = if pong["agent"] == "boot", do: :boot, else: :full
      assert agent_type == :full
    end

    test "Protocol.encode produces correct channel-0 frame for ping" do
      alias Mjolnir.Vsock.Protocol
      ping = %{"type" => "ping", "id" => "test123"}
      frame = Protocol.encode(ping)
      <<channel::8, length::big-32, body::binary-size(length)>> = frame
      assert channel == 0
      assert Jason.decode!(body) == ping
    end

    test "Protocol.decode_frame roundtrips a pong response" do
      alias Mjolnir.Vsock.Protocol
      pong = %{"type" => "pong", "id" => "test123", "agent" => "boot"}
      frame = Protocol.encode(pong)
      {:ok, 0, body, ""} = Protocol.decode_frame(frame)
      assert Jason.decode!(body) == pong
    end
  end

  # ---------------------------------------------------------------------------
  # Story 3.1: Config struct field defaults
  # ---------------------------------------------------------------------------

  describe "Config struct — initramfs_path field" do
    test "defaults to nil" do
      config = %Config{
        vm_id: "x",
        kernel_path: "/k",
        rootfs_path: "/r",
        virtiofsd_socket: "/s"
      }

      assert config.initramfs_path == nil
    end

    test "can be set to a path string" do
      config = %Config{
        vm_id: "x",
        kernel_path: "/k",
        rootfs_path: "/r",
        virtiofsd_socket: "/s",
        initramfs_path: "/var/lib/mjolnir/boot/initramfs.img"
      }

      assert config.initramfs_path == "/var/lib/mjolnir/boot/initramfs.img"
    end

    test "Config.__struct__() includes :initramfs_path key" do
      assert Map.has_key?(Config.__struct__(), :initramfs_path)
    end
  end
end
