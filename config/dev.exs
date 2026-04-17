import Config

config :logger, level: :info

# Dev uses the same kernel/base images as prod (installed by bootstrap)
# but separate VM storage and sockets to avoid conflicts
config :mjolnir,
  # Shared resources (read-only, installed by bootstrap)
  btrfs_root: "/var/lib/mjolnir/btrfs",
  kernel_path: "/var/lib/mjolnir/vmlinux",

  # Dev-specific paths (isolated from prod)
  vm_storage_subdir: "@vms-dev",
  socket_dir: "/tmp/mjolnir-dev",

  # Auto-inject current guest agent — path relative to project root (works for any checkout location)
  guest_agent_bin: Path.join(File.cwd!(), "native/target/x86_64-unknown-linux-musl/release/mjolnir-agent")

config :mjolnir, :auth,
  bypass_localhost: true,
  issuer: "https://connect.identikey.io/realms/identikey",
  audience: "mjolnir"
