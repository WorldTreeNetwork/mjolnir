import Config

config :mjolnir,
  # Hypervisor
  hypervisor: Mjolnir.Hypervisor.CloudHypervisor,

  # Paths
  btrfs_root: "/var/lib/mjolnir/btrfs",
  kernel_path: "/var/lib/mjolnir/vmlinux",
  ch_kernel_path: "/var/lib/mjolnir/vmlinux-ch",
  firecracker_bin: "/usr/local/bin/firecracker",
  cloud_hypervisor_bin: "/usr/local/bin/cloud-hypervisor",
  virtiofsd_bin: "/usr/libexec/virtiofsd",
  vm_storage_subdir: "@vms",

  # Defaults
  default_vcpus: 2,
  default_memory_mb: 512,
  default_base_image: "arch",

  # Sockets
  socket_dir: "/tmp/mjolnir",

  # Durability: per-VM intent state (one JSON file per VM)
  state_dir: "/var/lib/mjolnir/state",

  # HTTP API
  api_port: 4000,

  # Dormant registry persist interval (ms). 0 = instant (flush every change).
  dormant_flush_delay_ms: 250,

  # Guest agent binary to inject into rootfs on boot (nil = skip injection)
  guest_agent_bin: nil,

  # Initramfs image for two-phase boot (nil = legacy direct virtiofs boot)
  # Set to /var/lib/mjolnir/boot/initramfs.img to enable initramfs mode.
  # Override at runtime via MJOLNIR_INITRAMFS_PATH env var.
  initramfs_path: nil,

  # SSH (nil = no default key injection; can be a path or inline key string)
  default_ssh_public_key: nil,

  # Web gateway domain for Iroh-enabled VMs
  gateway_domain: "vm.worldtree.network"

# Auth defaults
config :mjolnir, :auth,
  bypass_localhost: false,
  issuer: "https://connect.identikey.io/realms/identikey",
  audience: "mjolnir"

import_config "#{config_env()}.exs"
