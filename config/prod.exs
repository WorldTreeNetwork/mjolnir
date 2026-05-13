import Config

config :logger, level: :info

config :mjolnir,
  guest_agent_bin: "/opt/mjolnir/native/target/x86_64-unknown-linux-musl/release/mjolnir-agent",

  # OTP-managed Postgres sidecar. The mjolnir service runs as root for VM /
  # networking ops, but `postgres` and `initdb` refuse to run as root, so we
  # drop privileges to the `mjolnir_pg` user (created by the host bootstrap
  # script). Data and socket live under /var/lib/mjolnir.
  pg_enabled: true,
  pg_run_as: "mjolnir_pg",
  pg_data_dir: "/var/lib/mjolnir/pg",
  pg_socket_dir: "/var/run/mjolnir",
  pg_log_dir: "/var/log/mjolnir/pg"
