import Config

config :logger, level: :info

# Dev uses the same kernel/base images as prod (installed by bootstrap)
# but separate VM storage and sockets to avoid conflicts
config :mjolnir,
  # Shared resources (read-only, installed by bootstrap)
  btrfs_root: "/var/lib/mjolnir/btrfs",
  ch_kernel_path: "/var/lib/mjolnir/vmlinux-ch",

  # Dev-specific paths (isolated from prod)
  vm_storage_subdir: "@vms-dev",
  socket_dir: "/tmp/mjolnir-dev",

  # Deploy registry kept under the project so the dev BEAM needs no /var/lib perms.
  deploy_state_dir: Path.join(File.cwd!(), ".mjolnir-dev/deploy/registry"),
  blake3_bin: Path.expand("native/target/debug/mjolnir-b3"),
  biscuit_bin: Path.expand("native/target/debug/mjolnir-biscuit"),

  # Auto-inject current guest agent — path relative to project root (works for any checkout location)
  guest_agent_bin:
    Path.join(File.cwd!(), "native/target/x86_64-unknown-linux-musl/release/mjolnir-agent"),

  # OTP-managed Postgres sidecar — dev paths kept under the project so the
  # dev BEAM can run as a normal user without /var/lib write perms.
  pg_enabled: true,
  pg_data_dir: Path.join(File.cwd!(), ".mjolnir-dev/pg/data"),
  pg_socket_dir: Path.join(File.cwd!(), ".mjolnir-dev/pg/sock"),
  pg_log_dir: Path.join(File.cwd!(), ".mjolnir-dev/pg/log")

config :mjolnir, :auth,
  bypass_localhost: true,
  issuer: "https://connect.identikey.io/realms/identikey",
  audience: "mjolnir"
