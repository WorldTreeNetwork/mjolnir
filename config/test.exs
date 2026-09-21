import Config

config :logger, level: :warning

config :mjolnir,
  # Tests use a separate BTRFS root (symlinked by bootstrap)
  btrfs_root: "/var/lib/mjolnir/btrfs-test",
  socket_dir: "/tmp/mjolnir-test",
  # TAP devices are host-global, so a test BEAM sharing a host with a prod one
  # must name its interfaces distinctly or Cleanup's sweep will delete a
  # running production VM's TAP (mjolnir-0ut). "mjt-" does not contain "mj-",
  # so neither BEAM's sweep can see the other's interfaces.
  tap_prefix: "mjt-",
  state_dir: "/tmp/mjolnir-test/state",
  forge_state_dir: "/tmp/mjolnir-test/forge",
  forge_declarations_path: "/tmp/mjolnir-test/forge-declarations",
  # Still uses @vms subdir within the test btrfs root
  vm_storage_subdir: "@vms",
  api_port: 4001,
  sites_root: "/tmp/mjolnir-test/sites",
  secret_store_root: "/tmp/mjolnir-test/sites/keyspace",
  sites_materialized_root: "/tmp/mjolnir-test/sites/materialized",
  sites_token_dir: "/tmp/mjolnir-test/sites-tokens",
  deploy_state_dir: "/tmp/mjolnir-test/deploy/registry",
  # Post-snapshot guest health-verify + in-place reboot recovery (mjolnir-l4i)
  # probes a real guest agent over vsock; disable it under test so snapshot
  # paths don't depend on (or block on) a live guest.
  snapshot_verify_guest: false,
  blake3_bin: Path.expand("native/target/debug/mjolnir-b3")

config :mjolnir, :auth, bypass_localhost: true
