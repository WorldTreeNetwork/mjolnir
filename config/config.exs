import Config

config :mjolnir,
  # Hypervisor
  hypervisor: Mjolnir.Hypervisor.CloudHypervisor,

  # Paths
  btrfs_root: "/var/lib/mjolnir/btrfs",
  ch_kernel_path: "/var/lib/mjolnir/vmlinux-ch",
  cloud_hypervisor_bin: "/usr/local/bin/cloud-hypervisor",
  # /usr/local/bin, not the distro's /usr/libexec: Ubuntu noble ships virtiofsd
  # 1.10, which cannot serialize its inode table and so cannot survive a
  # snapshot/restore. Needs >= 1.11 for :virtiofsd_migration_mode below.
  virtiofsd_bin: "/usr/local/bin/virtiofsd",
  virtiofsd_migration_mode: "find-paths",
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

  # CI VM lease (mjolnir-urp): a VM tagged metadata["purpose"]="ci" must have
  # its server-side lease renewed by API activity or Health.Monitor reclaims
  # it via the normal Mjolnir.VM.stop teardown path. 1h matches the forgejo-
  # runner's own `timeout: 1h` and exceeds the longest single exec observed
  # (a cold cargo build — one ~6m14s exec with no API traffic in between).
  ci_lease_seconds: 60 * 60,

  # CI trash is reaped sooner than user trash (default 7d): a reclaimed CI VM
  # is disposable job output, not a workspace someone will want to restore
  # days later. Read from the trash sidecar's metadata.purpose — no new
  # plumbing needed (see Mjolnir.BTRFS.reap_trash/1).
  ci_trash_retention_seconds: 24 * 60 * 60,

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
  #
  # An apex MUST be listed here (or merged in via MJOLNIR_GATEWAY_APEXES) for
  # RouteReconciler to emit a [[route]] for it. A Deploy.Registry custom_domain
  # whose apex is missing produces no route at all, and the gateway answers the
  # bare apex with 400 "Empty subdomain" — an outage with no error anywhere in
  # the pipeline that created it.
  #
  # startupcentral.build was added at runtime via put_env on 2026-07-20 and never
  # persisted, so it survived only in the running BEAM. The next restart
  # (2026-08-07) regenerated apps.toml without it and took the site down for ~10
  # minutes. Runtime put_env is not a durable config mechanism; this list is.
  gateway_apexes: [
    "vm.worldtree.network",
    "worldtree.network",
    "identikey.io",
    "startupcentral.build"
  ],
  # Static routes for manually-provisioned apps not in Deploy.Registry. Each is
  # %{fqdn: "zine.identikey.io", vm_id: "<uuid>", port: 3000} (or app_name:).
  gateway_extra_domains: [],

  # IdentiKey sites — content-addressed chunk store + signed-record secret store.
  # See docs/plans/initiatives/identikey-sites.md.
  sites_root: "/var/lib/mjolnir/btrfs/@sites",
  secret_store_root: "/var/lib/mjolnir/btrfs/@sites/keyspace",
  # Plaintext snapshot trees written at publish time by Mjolnir.Sites.Materializer
  # and served directly by the gateway's static file handler. Layout:
  #   <root>/<identikey_fp>/<site_name>/snapshots/<snapshot_hash>/…
  #   <root>/<identikey_fp>/<site_name>/current  → snapshots/<snapshot_hash>
  # A derived cache — safe to delete, rebuildable with mix mjolnir.sites.materialize.
  # Scoped service credentials for unattended Sites publishing (CI). One JSON
  # file per token; only a SHA-256 of the secret is stored. Deliberately on the
  # filesystem rather than Postgres — auth must not depend on an optional
  # sidecar. See Mjolnir.Sites.TokenStore.
  sites_token_dir: "/var/lib/mjolnir/state/sites-tokens",
  sites_materialized_root: "/var/lib/mjolnir/btrfs/@sites/materialized",
  # Snapshot directories kept per site. Older ones are pruned after each
  # publish; the one `current` points at is never pruned. Rollback is a symlink
  # flip as long as the target is still retained.
  sites_snapshot_retention: 5,
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
  pg_tenant_listen_ip: nil,
  pg_tenants_file: "/var/lib/mjolnir/pg-tenants.json",
  deploy_secrets_dir: "/var/lib/mjolnir/deploy/secrets",
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
  audience: "mjolnir",
  # Public client `mj login` already uses. No new Keycloak client required;
  # device-code + PKCE is registered, authorization-code redirect_uris are not.
  client_id: "mjolnir-cli"

import_config "#{config_env()}.exs"
