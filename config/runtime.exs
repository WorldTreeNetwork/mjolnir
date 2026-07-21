import Config

# Allow runtime overrides via environment
if btrfs_root = System.get_env("MJOLNIR_BTRFS_ROOT") do
  config :mjolnir, btrfs_root: btrfs_root
end

if socket_dir = System.get_env("MJOLNIR_SOCKET_DIR") do
  config :mjolnir, socket_dir: socket_dir
end

if state_dir = System.get_env("MJOLNIR_STATE_DIR") do
  config :mjolnir, state_dir: state_dir
end

if escrow_dir = System.get_env("MJOLNIR_SECRET_ESCROW_DIR") do
  config :mjolnir, secret_escrow_dir: escrow_dir
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

case System.get_env("MJOLNIR_GATEWAY_ROUTES_ENABLED") do
  "true" -> config :mjolnir, gateway_routes_enabled: true
  "false" -> config :mjolnir, gateway_routes_enabled: false
  _ -> :ok
end

# :gateway_apexes is runtime-configurable so an operator can add a custom-domain
# apex DURABLY (e.g. in /etc/mjolnir/env) WITHOUT recompiling/redeploying the
# orchestrator — the value is re-read on every boot, so it survives restarts.
# MJOLNIR_GATEWAY_APEXES is a comma-separated apex list; each entry is MERGED
# into (added to) the compile-time default list from config.exs (dedup,
# compile-time defaults first). When the env var is unset (or contributes no
# non-empty entries), the resulting apex list is IDENTICAL to config.exs's.
# Mjolnir.Gateway.Routes.configured_apexes/0 reads this value unchanged.
case System.get_env("MJOLNIR_GATEWAY_APEXES") do
  nil ->
    :ok

  raw ->
    default_apexes =
      Application.get_env(:mjolnir, :gateway_apexes, [
        "vm.worldtree.network",
        "worldtree.network",
        "identikey.io"
      ])

    extra =
      raw
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    config :mjolnir, gateway_apexes: Enum.uniq(default_apexes ++ extra)
end

if base_image = System.get_env("MJOLNIR_BASE_IMAGE") do
  config :mjolnir, default_base_image: base_image
end

if guest_agent_bin = System.get_env("MJOLNIR_GUEST_AGENT_BIN") do
  config :mjolnir, guest_agent_bin: guest_agent_bin
end

if initramfs_path = System.get_env("MJOLNIR_INITRAMFS_PATH") do
  config :mjolnir, initramfs_path: initramfs_path
end

if flush_delay = System.get_env("MJOLNIR_DORMANT_FLUSH_DELAY_MS") do
  config :mjolnir, dormant_flush_delay_ms: String.to_integer(flush_delay)
end

if materialized_root = System.get_env("MJOLNIR_SITES_MATERIALIZED_ROOT") do
  config :mjolnir, sites_materialized_root: materialized_root
end

if retention = System.get_env("MJOLNIR_SITES_SNAPSHOT_RETENTION") do
  config :mjolnir, sites_snapshot_retention: String.to_integer(retention)
end

if recrypt_storage_url = System.get_env("MJOLNIR_RECRYPT_STORAGE_URL") do
  config :mjolnir,
    sites_storage_backend: Mjolnir.Sites.Storage.Recrypt,
    recrypt_storage_url: recrypt_storage_url
end

case System.get_env("MJOLNIR_PG_ENABLED") do
  "true" -> config :mjolnir, pg_enabled: true
  "false" -> config :mjolnir, pg_enabled: false
  _ -> :ok
end

if pg_data_dir = System.get_env("MJOLNIR_PG_DATA_DIR") do
  config :mjolnir, pg_data_dir: pg_data_dir
end

if pg_socket_dir = System.get_env("MJOLNIR_PG_SOCKET_DIR") do
  config :mjolnir, pg_socket_dir: pg_socket_dir
end

if pg_bin_dir = System.get_env("MJOLNIR_PG_BIN_DIR") do
  config :mjolnir, pg_bin_dir: pg_bin_dir
end

if pg_run_as = System.get_env("MJOLNIR_PG_RUN_AS") do
  config :mjolnir, pg_run_as: pg_run_as
end
