import Config

config :mjolnir,
  # Hypervisor
  hypervisor: Mjolnir.Hypervisor.CloudHypervisor,

  # Paths
  btrfs_root: "/var/lib/mjolnir/btrfs",
  ch_kernel_path: "/var/lib/mjolnir/vmlinux-ch",
  cloud_hypervisor_bin: "/usr/local/bin/cloud-hypervisor",
  virtiofsd_bin: "/usr/libexec/virtiofsd",
  vm_storage_subdir: "@vms",

  # Defaults
  default_vcpus: 2,
  default_memory_mb: 512,
  default_base_image: "ubuntu-24.04",

  # Sockets
  socket_dir: "/tmp/mjolnir",

  # Durability: per-VM intent state (one JSON file per VM)
  state_dir: "/var/lib/mjolnir/state",

  # secrets_mode: :managed — per-VM LUKS passphrase escrow. Lives OUTSIDE
  # btrfs_root (the data volume), so it is never captured by a VM snapshot.
  # The host re-injects the escrowed passphrase over vsock on boot + wake.
  # Override at runtime via MJOLNIR_SECRET_ESCROW_DIR.
  secret_escrow_dir: "/var/lib/mjolnir/escrow",

  # Durability: soft-deleted VM subvolumes are moved to @trash and reaped after
  # this window (default 7 days), so a deletion is recoverable in the interim.
  trash_retention_seconds: 7 * 24 * 60 * 60,

  # Durability: Reconcile retirement policy (mjolnir-5fu). A :running record
  # that fails to resume this many consecutive times, OR whose failure streak
  # is older than the TTL, is retired to intent=:failed so it stops being
  # resumed on every tick/restart. Rootfs is preserved; revive via mj/API.
  reconcile_max_failures: 10,
  reconcile_failure_ttl_seconds: 24 * 60 * 60,

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

  # Gateway local-route generation (Mjolnir.Gateway.Routes). When enabled, the
  # RouteReconciler renders /etc/mjolnir/gateway.d/apps.toml from live VM +
  # Deploy.Registry state so co-located VMs are served over direct host→guest
  # TCP (no ~7s Iroh cold-start). OFF by default so `mix test` and Macs never
  # write /etc; prod.exs flips it on. See docs/plans/gateway-local-routing.md.
  gateway_routes_enabled: false,
  # Drop-in file the gateway SIGHUP-merges (must contain only [[route]] blocks).
  gateway_routes_path: "/etc/mjolnir/gateway.d/apps.toml",
  # Apexes the gateway declares as [[domain]] entries. A custom-domain fqdn is
  # split into (subdomain, apex) by the LONGEST matching apex suffix.
  gateway_apexes: ["vm.worldtree.network", "worldtree.network", "identikey.io"],
  # Static routes for manually-provisioned apps not in Deploy.Registry. Each is
  # %{fqdn: "zine.identikey.io", vm_id: "<uuid>", port: 3000} (or app_name:).
  gateway_extra_domains: [],

  # IdentiKey sites — content-addressed chunk store + signed-record secret store.
  # See docs/plans/initiatives/identikey-sites.md.
  sites_root: "/var/lib/mjolnir/btrfs/@sites",
  secret_store_root: "/var/lib/mjolnir/btrfs/@sites/keyspace",
  sites_ots_upgrade_interval_ms: 30 * 60 * 1_000,
  # Chunk-store backend behind Mjolnir.Sites.Store. Default keeps blobs on local
  # BTRFS (recrypt LocalFileStorage layout). Switch to
  # Mjolnir.Sites.Storage.Recrypt to delegate to the recrypt-storage crate via
  # the recrypt-server sidecar (real Bao outboards + S3/B2). See
  # docs/plans/initiatives/identikey-sites.md ("Storage integration decision").
  sites_storage_backend: Mjolnir.Sites.Storage.Local,
  # Base URL of the recrypt-server sidecar (only read by the Recrypt backend).
  # Overridable via MJOLNIR_RECRYPT_STORAGE_URL.
  recrypt_storage_url: nil,

  # Forgejo runner — managed as an Erlang Port. Disabled by default so unit
  # tests and dev machines without the binary stay green. Operator enables in
  # prod via runner_enabled: true or MJOLNIR_RUNNER_ENABLED=true.
  runner_enabled: false,
  runner_binary_path: "/usr/local/bin/forgejo-runner-mjolnir",
  runner_config_path: "/etc/mjolnir/runner.yml",
  runner_state_dir: "/var/lib/mjolnir/runner",
  runner_forgejo_url: "http://127.0.0.1:3000",
  runner_labels: ["ubuntu-24.04:host"],
  runner_max_concurrent_jobs: 1,
  runner_log_level: "info",

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

# Allowed host paths for extra_mounts in VM spawn API. Empty = disabled.
# In prod, set to e.g. ["/var/lib/forgejo/data/repositories"].
config :mjolnir,
  allowed_mount_prefixes: []

# Syslog-over-vsock transport. VMs stream syslog via vsock channel 2.
# See lib/mjolnir/syslog/.
config :mjolnir, :syslog,
  enabled: true,
  vsock_channel: 2,
  sinks: [:eventbus, :logger]

# Auth defaults
config :mjolnir, :auth,
  bypass_localhost: false,
  issuer: "https://connect.identikey.io/realms/identikey",
  audience: "mjolnir"

import_config "#{config_env()}.exs"
