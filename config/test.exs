import Config

config :logger, level: :warning

config :mjolnir,
  # Tests use a separate BTRFS root (symlinked by bootstrap)
  btrfs_root: "/var/lib/mjolnir/btrfs-test",
  socket_dir: "/tmp/mjolnir-test",
  # Still uses @vms subdir within the test btrfs root
  vm_storage_subdir: "@vms",
  api_port: 4001

config :mjolnir, :auth, bypass_localhost: true
