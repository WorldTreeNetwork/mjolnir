import Config

config :mjolnir,
  # Paths
  btrfs_root: "/var/lib/mjolnir/btrfs",
  kernel_path: "/var/lib/mjolnir/vmlinux",
  firecracker_bin: "/usr/local/bin/firecracker",
  vm_storage_subdir: "@vms",

  # Defaults
  default_vcpus: 2,
  default_memory_mb: 512,
  default_base_image: "debian-12",

  # Sockets
  socket_dir: "/tmp/mjolnir",

  # API
  api_port: 4000

import_config "#{config_env()}.exs"
