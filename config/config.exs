import Config

config :mjolnir,
  # Hypervisor
  hypervisor: Mjolnir.Hypervisor.Firecracker,

  # Paths
  btrfs_root: "/var/lib/mjolnir/btrfs",
  kernel_path: "/var/lib/mjolnir/vmlinux",
  ch_kernel_path: "/var/lib/mjolnir/vmlinux-ch",
  firecracker_bin: "/usr/local/bin/firecracker",
  cloud_hypervisor_bin: "/usr/local/bin/cloud-hypervisor",
  vm_storage_subdir: "@vms",

  # Defaults
  default_vcpus: 2,
  default_memory_mb: 512,
  default_base_image: "ubuntu-24.04",

  # Sockets
  socket_dir: "/tmp/mjolnir",

  # HTTP API
  api_port: 4000,

  # SSH (nil = no default key injection; can be a path or inline key string)
  default_ssh_public_key: nil

# Auth defaults
config :mjolnir, :auth,
  bypass_localhost: false,
  issuer: "https://connect.identikey.io/realms/identikey",
  audience: "mjolnir"

import_config "#{config_env()}.exs"
