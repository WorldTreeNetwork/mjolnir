import Config

config :mjolnir,
  # Hypervisor
  hypervisor: Mjolnir.Hypervisor.CloudHypervisor,

  # Paths
  btrfs_root: "/var/lib/mjolnir/btrfs",
  kernel_path: "/var/lib/mjolnir/vmlinux",
  ch_kernel_path: "/var/lib/mjolnir/vmlinux-ch",
  firecracker_bin: "/usr/local/bin/firecracker",
  cloud_hypervisor_bin: "/usr/local/bin/cloud-hypervisor",
  virtiofsd_bin: "/usr/libexec/virtiofsd",
  vm_storage_subdir: "@vms",

  # Defaults
  default_vcpus: 2,
  default_memory_mb: 512,
  default_base_image: "arch",

  # Sockets
  socket_dir: "/tmp/mjolnir",

  # Durability: per-VM intent state (one JSON file per VM)
  state_dir: "/var/lib/mjolnir/state",

  # Forge (host config reconciler) — see docs/plans/host-reconcile.md
  forge_state_dir: "/var/lib/mjolnir/forge/state",
  forge_declarations_path: "forge/declarations",

  # HTTP API
  api_port: 4000,

  # Dormant registry persist interval (ms). 0 = instant (flush every change).
  dormant_flush_delay_ms: 250,

  # Guest agent binary to inject into rootfs on boot (nil = skip injection)
  guest_agent_bin: nil,

  # Initramfs image for two-phase boot (nil = legacy direct virtiofs boot)
  # Set to /var/lib/mjolnir/boot/initramfs.img to enable initramfs mode.
  # Override at runtime via MJOLNIR_INITRAMFS_PATH env var.
  initramfs_path: nil,

  # SSH (nil = no default key injection; can be a path or inline key string)
  default_ssh_public_key: nil,

  # Web gateway domain for Iroh-enabled VMs
  gateway_domain: "vm.worldtree.network",

  # IdentiKey sites — content-addressed chunk store + signed-record secret store.
  # See docs/plans/initiatives/identikey-sites.md.
  sites_root: "/var/lib/mjolnir/btrfs/@sites",
  secret_store_root: "/var/lib/mjolnir/btrfs/@sites/keyspace",
  sites_ots_upgrade_interval_ms: 30 * 60 * 1_000,

  # OTP-managed Postgres sidecar. See lib/mjolnir/postgres/. Disabled by
  # default so unit tests and CI without local Postgres stay green; dev.exs
  # and prod.exs flip it on. Override via MJOLNIR_PG_ENABLED at runtime.
  pg_enabled: false,
  pg_managed: true,
  pg_data_dir: "/var/lib/mjolnir/pg",
  pg_socket_dir: "/var/run/mjolnir",
  pg_log_dir: "/var/log/mjolnir/pg",
  pg_bin_dir: "/usr/bin",
  pg_run_as: nil,
  pg_bootstrap_role: "mjolnir_admin",
  pg_roles: ["mjolnir_admin", "mjolnir_sites"],
  pg_database: "mjolnir",
  pg_pool_size: 10,
  ecto_repos: [Mjolnir.Repo]

# Auth defaults
config :mjolnir, :auth,
  bypass_localhost: false,
  issuer: "https://connect.identikey.io/realms/identikey",
  audience: "mjolnir"

import_config "#{config_env()}.exs"
