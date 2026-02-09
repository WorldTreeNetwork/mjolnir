import Config

# Allow runtime overrides via environment
if btrfs_root = System.get_env("MJOLNIR_BTRFS_ROOT") do
  config :mjolnir, btrfs_root: btrfs_root
end

if socket_dir = System.get_env("MJOLNIR_SOCKET_DIR") do
  config :mjolnir, socket_dir: socket_dir
end

if api_port = System.get_env("MJOLNIR_API_PORT") do
  config :mjolnir, api_port: String.to_integer(api_port)
end
