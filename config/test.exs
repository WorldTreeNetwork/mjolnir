import Config

# Disposable mint root so `mix test` can boot without the operator file at
# `/var/lib/mjolnir/biscuit-root`. Production config keeps that path and still
# fails closed when it is missing. The host does not create it. This file is a
# 32-byte Ed25519 seed, mode 0600, outside the test BTRFS root and escrow.
# Rewritten on each config load. `biscuit_public_hex` stays unset here so boot
# publishes the public half of this file.
biscuit_test_root = "/tmp/mjolnir-test/biscuit-root"
File.mkdir_p!(Path.dirname(biscuit_test_root))
File.write!(biscuit_test_root, Base.encode16(:crypto.strong_rand_bytes(32), case: :lower) <> "\n")
File.chmod!(biscuit_test_root, 0o600)

config :logger, level: :warning

config :mjolnir,
  vmm_slice: "mjt-vms.slice",
  vmm_scope_prefix: "mjt-",
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
  blake3_bin: Path.expand("native/target/debug/mjolnir-b3"),
  biscuit_bin: Path.expand("native/target/debug/mjolnir-biscuit"),
  biscuit_root_path: biscuit_test_root

# Edge-key tests pass a per-test auth_dir. This fallback is still outside the
# test BTRFS tree and prevents accidental use of the production path.
config :mjolnir, auth_dir: "/tmp/mjolnir-test/auth"

config :mjolnir, :auth, bypass_localhost: true
# Lets Plug tests act as the operator when they also set bypass_localhost.
# A production release never sets this. Peer address alone is not enough.
config :mjolnir, test_operator: true
