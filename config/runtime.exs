import Config

# Allow runtime overrides via environment
if btrfs_root = System.get_env("MJOLNIR_BTRFS_ROOT") do
  config :mjolnir, btrfs_root: btrfs_root
end

if socket_dir = System.get_env("MJOLNIR_SOCKET_DIR") do
  config :mjolnir, socket_dir: socket_dir
end

if System.get_env("MJOLNIR_AUTH_BYPASS_LOCALHOST", "false") == "true" do
  config :mjolnir, :auth, bypass_localhost: true
end

if issuer = System.get_env("MJOLNIR_AUTH_ISSUER") do
  config :mjolnir, :auth,
    issuer: issuer,
    audience: System.get_env("MJOLNIR_AUTH_AUDIENCE", "mjolnir")
end

if api_port = System.get_env("MJOLNIR_API_PORT") do
  config :mjolnir, api_port: String.to_integer(api_port)
end

if guest_agent_bin = System.get_env("MJOLNIR_GUEST_AGENT_BIN") do
  config :mjolnir, guest_agent_bin: guest_agent_bin
end
