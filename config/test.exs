import Config

config :logger, level: :warning

config :mjolnir,
  # Use test-specific paths
  btrfs_root: "/var/lib/mjolnir/btrfs-test",
  socket_dir: "/tmp/mjolnir-test",
  api_port: 0
