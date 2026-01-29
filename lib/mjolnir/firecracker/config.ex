defmodule Mjolnir.Firecracker.Config do
  @moduledoc """
  Builds Firecracker VM configuration.
  """

  use TypedStruct

  typedstruct do
    field(:vm_id, String.t(), enforce: true)
    field(:kernel_path, String.t(), enforce: true)
    field(:rootfs_path, String.t(), enforce: true)
    field(:base_image, String.t(), default: "debian-12")
    field(:vcpu_count, pos_integer(), default: 2)
    field(:mem_size_mib, pos_integer(), default: 512)
    field(:boot_args, String.t(), default: "console=ttyS0 reboot=k panic=1 pci=off")
    field(:vsock_cid, pos_integer(), default: 3)
    # Network interface config: %{tap_name: String.t(), guest_mac: String.t(), guest_ip: String.t()}
    field(:network_interface, map(), default: nil)
  end

  @doc """
  Generates the boot-source configuration for Firecracker API.
  """
  def boot_source(%__MODULE__{} = config) do
    %{
      "kernel_image_path" => config.kernel_path,
      "boot_args" => config.boot_args
    }
  end

  @doc """
  Generates the drive configuration for Firecracker API.
  """
  def drives(%__MODULE__{} = config) do
    [
      %{
        "drive_id" => "rootfs",
        "path_on_host" => config.rootfs_path,
        "is_root_device" => true,
        "is_read_only" => false
      }
    ]
  end

  @doc """
  Generates the machine-config for Firecracker API.
  """
  def machine_config(%__MODULE__{} = config) do
    %{
      "vcpu_count" => config.vcpu_count,
      "mem_size_mib" => config.mem_size_mib,
      "smt" => false
    }
  end

  @doc """
  Generates the vsock configuration for Firecracker API.
  """
  def vsock(%__MODULE__{} = config, socket_path) do
    %{
      "guest_cid" => config.vsock_cid,
      "uds_path" => socket_path
    }
  end

  @doc """
  Generates the network-interface configuration for Firecracker API.
  Returns nil if no network interface is configured.
  """
  def network_interface(%__MODULE__{network_interface: nil}), do: nil

  def network_interface(%__MODULE__{network_interface: net}) do
    %{
      "iface_id" => "eth0",
      "guest_mac" => net.guest_mac,
      "host_dev_name" => net.tap_name
    }
  end
end
