import Config

config :logger, level: :info

config :mjolnir,
  guest_agent_bin: "/opt/mjolnir/native/target/x86_64-unknown-linux-musl/release/mjolnir-agent",

  # Gateway local-route generation — serve co-located VMs over direct TCP.
  gateway_routes_enabled: true,
  # zine was provisioned manually (not via Deploy.Registry), so it is routed via
  # this static map. vm_id is stable across restart/restore; it changes only if
  # zine is re-provisioned, at which point this must be updated (or zine migrated
  # to Deploy so its Registry.Entry carries custom_domain + port). The route is
  # only emitted while the VM is running+local, so a stale id self-heals to "no
  # route" rather than a bad backend.
  gateway_extra_domains: [
    %{fqdn: "zine.identikey.io", vm_id: "076adf62-b3e1-4696-8427-1b20faf3fd9c", port: 3000}
  ],

  # OTP-managed Postgres sidecar. The mjolnir service runs as root for VM /
  # networking ops, but `postgres` and `initdb` refuse to run as root, so we
  # drop privileges to the `mjolnir_pg` user (created by the host bootstrap
  # script). Data and socket live under /var/lib/mjolnir.
  pg_enabled: true,
  pg_run_as: "mjolnir_pg",
  pg_data_dir: "/var/lib/mjolnir/pg",
  pg_socket_dir: "/var/run/mjolnir",
  pg_log_dir: "/var/log/mjolnir/pg",
  pg_tenant_listen_ip: "10.200.0.1",
  pg_tenants_file: "/var/lib/mjolnir/pg-tenants.json"
