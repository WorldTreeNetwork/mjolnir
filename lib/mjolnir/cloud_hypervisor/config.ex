defmodule Mjolnir.CloudHypervisor.Config do
  @moduledoc """
  Builds Cloud Hypervisor VM configuration.

  Cloud Hypervisor uses a single unified configuration payload for `vm.create`.

  Uses virtio-fs for rootfs sharing (via virtiofsd) instead of virtio-blk disk images.
  The virtio-fs tag `myfs` is used consistently across CH config, boot_args, and guest fstab.

  Pinned to Cloud Hypervisor v50.0 API specification.
  """

  use TypedStruct

  typedstruct do
    field(:vm_id, String.t(), enforce: true)
    field(:kernel_path, String.t(), enforce: true)
    field(:rootfs_path, String.t(), enforce: true)
    field(:base_image, String.t(), default: "ubuntu-24.04")
    field(:vcpu_count, pos_integer(), default: 2)
    field(:mem_size_mib, pos_integer(), default: 512)

    field(:boot_args, String.t(),
      default: "console=ttyS0 reboot=k panic=1 root=myfs rootfstype=virtiofs rw net.ifnames=0"
    )

    # CID must be unique per concurrent VM. CID 0-2 are reserved by the kernel.
    # When running multiple VMs, callers must set a unique CID per VM.
    field(:vsock_cid, pos_integer(), default: 3)

    # Network interface config: %{tap_name: String.t(), guest_mac: String.t(), guest_ip: String.t()}
    field(:network_interface, map(), default: nil)
    # Snapshot name to spawn from (instead of base_image)
    field(:snapshot, String.t(), default: nil)
    # Path to the virtiofsd vhost-user socket for this VM
    field(:virtiofsd_socket, String.t(), default: nil)
    # Extra virtio-fs mounts beyond the primary rootfs. Each entry is a map:
    # %{tag: String.t(), socket: String.t()}
    field(:extra_fs, list(map()), default: [])
    # Initramfs image path for two-phase boot (nil = legacy direct virtiofs boot)
    field(:initramfs_path, String.t(), default: nil)
    # Preserve iroh key from snapshot (default: false, generates unique key)
    field(:preserve_iroh_key, boolean(), default: false)
  end

  @doc """
  Generates the full vm.create payload for Cloud Hypervisor API.

  Returns a map containing all VM configuration sections:
  - payload (kernel, cmdline)
  - cpus (boot_vcpus, max_vcpus)
  - memory (size in bytes, shared: true for virtio-fs)
  - fs (array of virtio-fs configs)
  - net (array of network interface configs, optional)
  - vsock (cid, socket path)
  """
  def vm_create_payload(%__MODULE__{} = config, vsock_path) do
    serial_log = Path.join(Path.dirname(vsock_path), "#{config.vm_id}_serial.log")

    payload = %{
      "payload" => kernel_payload(config),
      "cpus" => cpus_config(config),
      "memory" => memory_config(config),
      "fs" => fs_config(config),
      "vsock" => vsock_config(config, vsock_path),
      "rng" => rng_config(config),
      "serial" => %{"mode" => "File", "file" => serial_log},
      "console" => %{"mode" => "Off"}
    }

    case network_config(config) do
      nil -> payload
      net -> Map.put(payload, "net", net)
    end
  end

  @doc """
  Generates the kernel payload section.

  When `initramfs_path` is nil, returns legacy payload (kernel + cmdline only).
  When set, adds `"initramfs"` key for two-phase initramfs boot.
  """
  def kernel_payload(%__MODULE__{initramfs_path: nil} = config) do
    %{
      "kernel" => config.kernel_path,
      "cmdline" => config.boot_args
    }
  end

  def kernel_payload(%__MODULE__{} = config) do
    %{
      "kernel" => config.kernel_path,
      "cmdline" => config.boot_args,
      "initramfs" => config.initramfs_path
    }
  end

  @doc """
  Generates the CPUs configuration.
  """
  def cpus_config(%__MODULE__{} = config) do
    %{
      "boot_vcpus" => config.vcpu_count,
      "max_vcpus" => config.vcpu_count
    }
  end

  @doc """
  Generates the memory configuration.

  Cloud Hypervisor expects memory size in bytes, not MiB.
  `shared: true` is required for virtio-fs shared memory access.
  """
  def memory_config(%__MODULE__{} = config) do
    %{
      "size" => config.mem_size_mib * 1024 * 1024,
      "shared" => true
    }
  end

  @doc "Generates the virtio-fs configuration."
  def fs_config(%__MODULE__{virtiofsd_socket: nil}) do
    raise ArgumentError, "virtiofsd_socket must be set for virtio-fs configuration"
  end

  def fs_config(%__MODULE__{} = config) do
    primary = %{
      "tag" => "myfs",
      "socket" => config.virtiofsd_socket,
      "num_queues" => 1,
      "queue_size" => 1024
    }

    extra =
      Enum.map(config.extra_fs, fn %{tag: tag, socket: socket} ->
        %{
          "tag" => tag,
          "socket" => socket,
          "num_queues" => 1,
          "queue_size" => 1024
        }
      end)

    [primary | extra]
  end

  @doc """
  Generates the virtio-rng configuration.

  Until mjolnir-3y6.12 every VM booted with **no RNG device at all**, leaving
  the guest kernel's CRNG dependent entirely on what it could scrape from its
  own (virtualised, low-entropy) environment. The guest kernel has the
  `virtio_rng` driver; nothing was giving it a device to bind.

  This is a prerequisite for, not a solution to, the snapshot-cloning problem
  (mjolnir-3y6.5). A virtio-rng device gives the guest a *source* of host
  entropy but does not force a reseed at any particular moment, so two VMs
  thawed from one memory image still wake with identical CRNG state and can
  emit identical session keys and nonces before the driver is next polled.
  `Mjolnir.Entropy` handles the forcing; this handles the supply.
  """
  def rng_config(%__MODULE__{}) do
    # /dev/urandom, not /dev/random: this is the *host* side, where urandom is
    # already cryptographically seeded and never blocks. Using /dev/random here
    # would stall VM boot on a freshly-booted host for no security gain.
    %{"src" => "/dev/urandom"}
  end

  @doc """
  Generates the vsock configuration.
  """
  def vsock_config(%__MODULE__{} = config, socket_path) do
    %{
      "cid" => config.vsock_cid,
      "socket" => socket_path
    }
  end

  @doc """
  Generates the network configuration.

  Returns an array with a single network interface, or nil if not configured.
  """
  def network_config(%__MODULE__{network_interface: nil}), do: nil

  def network_config(%__MODULE__{network_interface: net}) do
    [
      %{
        "tap" => net.tap_name,
        "mac" => net.guest_mac
      }
    ]
  end
end
