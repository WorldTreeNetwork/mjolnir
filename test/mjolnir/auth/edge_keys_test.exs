defmodule Mjolnir.Auth.EdgeKeysTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Auth.EdgeKeys

  @now 1_800_000_000

  setup do
    root =
      Path.join([
        System.tmp_dir!(),
        "mjolnir-edge-keys",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    auth_dir = Path.join(root, "auth")
    btrfs_root = Path.join(root, "btrfs")
    File.mkdir_p!(btrfs_root)

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, opts: [auth_dir: auth_dir, btrfs_root: btrfs_root, now: @now]}
  end

  test "XID hashes exactly the raw 32-byte inception public", %{opts: opts} do
    public = :binary.list_to_bin(Enum.to_list(0..31))

    assert EdgeKeys.edge_xid(public) ==
             "630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd"

    stable = EdgeKeys.generate_keypair()
    op = EdgeKeys.generate_operational()

    assert {:ok, delegation} =
             EdgeKeys.delegate(stable, op.keypair.ed25519_public, "kid-1",
               now: 1,
               exp: 100
             )

    expected =
      "89746964656e74696b65792d6d6a6f6c6e69722f76316d6f702d64656c65676174696f6e" <>
        "5820" <>
        Base.encode16(op.keypair.ed25519_public, case: :lower) <>
        "656b69642d317840" <>
        Base.encode16(delegation.edge_xid, case: :lower) <>
        "826a656467652d70726f6f66686361702d6d696e74011864f5"

    assert Base.encode16(EdgeKeys.delegation_signing_bytes(delegation), case: :lower) == expected
    assert {:ok, _} = EdgeKeys.provision(opts)
  end

  test "offline chain verifies and ordinary signing does not need the stable private", %{
    opts: opts
  } do
    assert {:ok, state} =
             EdgeKeys.provision(Keyword.put(opts, :persist_stable_private, false))

    refute File.exists?(Path.join(opts[:auth_dir], "stable.key"))
    assert {:ok, loaded} = EdgeKeys.load(opts)
    delegation = hd(loaded.delegations)

    assert :ok =
             EdgeKeys.verify_chain(
               loaded.edge_xid,
               loaded.stable_public,
               delegation,
               now: @now
             )

    assert {:ok, %{kid: kid, signature: signature}} =
             EdgeKeys.sign_operational(loaded, "edge-proof", "challenge", now: @now)

    assert kid == state.current_kid
    assert is_binary(signature) and byte_size(signature) == 64

    assert {:error, :stable_private_unavailable} =
             EdgeKeys.rotate(Keyword.put(opts, :now, @now + 1))
  end

  test "rotation overlaps and keeps unexpired K1 verification material", %{opts: opts} do
    assert {:ok, first} = EdgeKeys.provision(Keyword.merge(opts, exp: @now + 1_000))
    k1 = hd(first.delegations)

    assert {:ok, rotated} =
             EdgeKeys.rotate(Keyword.merge(opts, now: @now + 10, exp: @now + 2_000))

    assert rotated.current_kid != first.current_kid
    assert Enum.any?(rotated.delegations, &(&1.kid == first.current_kid))

    assert :ok =
             EdgeKeys.verify_chain(first.edge_xid, first.stable_public, k1,
               now: @now + 20,
               supersessions: rotated.supersessions
             )

    assert :ok =
             EdgeKeys.verify_capability_window(rotated, first.current_kid, @now + 999,
               now: @now + 20
             )

    assert {:error, :capability_outlives_delegation} =
             EdgeKeys.verify_capability_window(rotated, first.current_kid, @now + 1_001,
               now: @now + 20
             )
  end

  test "resolved snapshot paths and symlink aliases under btrfs are rejected", ctx do
    unsafe = Path.join(ctx.opts[:btrfs_root], "auth")

    assert {:error, :unsafe_auth_path} =
             EdgeKeys.provision(Keyword.put(ctx.opts, :auth_dir, unsafe))

    File.mkdir_p!(unsafe)
    alias_path = Path.join(ctx.root, "auth-alias")
    File.ln_s!(unsafe, alias_path)

    assert {:error, :unsafe_auth_path} =
             EdgeKeys.safe_auth_dir(Keyword.put(ctx.opts, :auth_dir, alias_path))
  end

  test "no pin is not trust on first use", %{opts: opts} do
    stable = EdgeKeys.generate_keypair()
    op = EdgeKeys.generate_operational()

    assert {:ok, delegation} =
             EdgeKeys.delegate(stable, op.keypair.ed25519_public, op.kid,
               now: @now,
               exp: @now + 100
             )

    assert {:error, :missing_pin} =
             EdgeKeys.verify_chain(nil, stable.ed25519_public, delegation, now: @now)

    assert {:ok, _} = EdgeKeys.provision(opts)
  end

  test "tampered delegation and wrong purpose fail", %{opts: opts} do
    stable = EdgeKeys.generate_keypair()
    op = EdgeKeys.generate_operational()

    assert {:ok, delegation} =
             EdgeKeys.delegate(stable, op.keypair.ed25519_public, op.kid,
               now: @now,
               exp: @now + 100
             )

    pin = EdgeKeys.edge_xid(stable)
    tampered = %{delegation | exp: delegation.exp + 1}
    wrong_purpose = %{delegation | purposes: ["edge-proof"]}

    assert {:error, :invalid_delegation_signature} =
             EdgeKeys.verify_delegation(pin, stable.ed25519_public, tampered, now: @now)

    assert {:error, :invalid_delegation} =
             EdgeKeys.verify_delegation(pin, stable.ed25519_public, wrong_purpose, now: @now)

    assert {:ok, _} = EdgeKeys.provision(opts)
  end

  test "a reused kid cannot substitute another public key", %{opts: opts} do
    stable = EdgeKeys.generate_keypair()
    first = EdgeKeys.generate_operational()
    substitute = EdgeKeys.generate_operational()

    assert {:ok, d1} =
             EdgeKeys.delegate(stable, first.keypair.ed25519_public, "reused",
               now: @now,
               exp: @now + 100
             )

    assert {:ok, d2} =
             EdgeKeys.delegate(stable, substitute.keypair.ed25519_public, "reused",
               now: @now,
               exp: @now + 100
             )

    assert {:error, :reused_kid} =
             EdgeKeys.verify_chain(EdgeKeys.edge_xid(stable), stable.ed25519_public, d2,
               now: @now,
               delegations: [d1, d2]
             )

    assert {:ok, _} = EdgeKeys.provision(opts)
  end

  test "missing established state fails closed even when the root file remains", %{opts: opts} do
    assert {:ok, _} = EdgeKeys.provision(opts)
    File.rm!(Path.join(opts[:auth_dir], "bundle.json"))

    assert {:error, :missing_operational_state} = EdgeKeys.load(opts)
    assert {:error, :missing_operational_state} = EdgeKeys.load_or_initialize(opts)
  end

  test "stale backup and old attestation cannot revive a superseded kid", %{opts: opts} do
    stable = EdgeKeys.generate_keypair()

    assert {:ok, stale} =
             EdgeKeys.provision(Keyword.merge(opts, stable_keypair: stable, exp: @now + 1_000))

    assert {:ok, old_attestation} =
             EdgeKeys.attest_restore(stable, stale, [],
               now: @now + 1,
               restore_id: "restore-before-k2"
             )

    assert {:ok, current} =
             EdgeKeys.rotate(
               Keyword.merge(opts,
                 stable_keypair: stable,
                 now: @now + 10,
                 exp: @now + 2_000,
                 supersede: true
               )
             )

    assert {:error, :invalid_restore} =
             EdgeKeys.activate_restore(stale, current.supersessions, old_attestation,
               auth_dir: Path.join(opts[:auth_dir], "restore-attempt"),
               btrfs_root: opts[:btrfs_root],
               now: @now + 11,
               current_evidence: true
             )

    assert {:ok, fresh_attestation} =
             EdgeKeys.attest_restore(stable, current, current.supersessions,
               now: @now + 11,
               restore_id: "restore-after-k2"
             )

    restore_dir = Path.join(opts[:root] || Path.dirname(opts[:auth_dir]), "restored")

    assert {:ok, restored} =
             EdgeKeys.activate_restore(current, current.supersessions, fresh_attestation,
               auth_dir: restore_dir,
               btrfs_root: opts[:btrfs_root],
               now: @now + 11,
               current_evidence: true
             )

    assert "restore-after-k2" in restored.restore_ids
  end

  test "stolen stable private means a new identity and pin", %{opts: opts} do
    leaked = EdgeKeys.generate_keypair()
    attacker_op = EdgeKeys.generate_operational()

    assert {:ok, attacker_delegation} =
             EdgeKeys.delegate(leaked, attacker_op.keypair.ed25519_public, attacker_op.kid,
               now: @now,
               exp: @now + 100
             )

    old_pin = EdgeKeys.edge_xid(leaked)

    assert :ok =
             EdgeKeys.verify_chain(old_pin, leaked.ed25519_public, attacker_delegation, now: @now)

    replacement = EdgeKeys.generate_keypair()
    replacement_pin = EdgeKeys.edge_xid(replacement)
    refute replacement_pin == old_pin

    assert {:error, :pin_mismatch} =
             EdgeKeys.verify_chain(
               replacement_pin,
               leaked.ed25519_public,
               attacker_delegation,
               now: @now
             )

    assert {:ok, _} = EdgeKeys.provision(opts)
  end

  test "late supersession revokes and does not authorize its named successor", %{opts: opts} do
    stable = EdgeKeys.generate_keypair()
    k1 = EdgeKeys.generate_operational()
    k2 = EdgeKeys.generate_operational()
    pin = EdgeKeys.edge_xid(stable)

    assert {:ok, delegation} =
             EdgeKeys.delegate(stable, k1.keypair.ed25519_public, k1.kid,
               now: @now,
               exp: @now + 1_000
             )

    assert {:ok, supersession} = EdgeKeys.supersede(stable, k1.kid, @now + 10, k2.kid)

    assert :ok =
             EdgeKeys.verify_chain(pin, stable.ed25519_public, delegation,
               now: @now + 9,
               supersessions: [supersession]
             )

    assert {:error, :superseded} =
             EdgeKeys.verify_chain(pin, stable.ed25519_public, delegation,
               now: @now + 500,
               supersessions: [supersession]
             )

    # Naming K2 in the revocation record is not a K2 delegation.
    # Swapping the kid under K1's signature fails closed.
    assert {:error, :invalid_delegation_signature} =
             EdgeKeys.verify_chain(pin, stable.ed25519_public, %{delegation | kid: k2.kid},
               now: @now + 500,
               supersessions: [supersession]
             )

    assert {:ok, _} = EdgeKeys.provision(opts)
  end

  test "private modes are restrictive at creation and checked again at open", %{opts: opts} do
    assert {:ok, _} = EdgeKeys.provision(opts)

    assert mode(opts[:auth_dir]) == 0o700
    assert mode(Path.join(opts[:auth_dir], "identity.json")) == 0o600
    assert mode(Path.join(opts[:auth_dir], "stable.key")) == 0o600
    assert mode(Path.join(opts[:auth_dir], "bundle.json")) == 0o600

    File.chmod!(Path.join(opts[:auth_dir], "bundle.json"), 0o644)
    assert {:error, :bad_permissions} = EdgeKeys.load(opts)

    File.chmod!(Path.join(opts[:auth_dir], "bundle.json"), 0o600)
    File.chmod!(opts[:auth_dir], 0o755)
    assert {:error, :bad_permissions} = EdgeKeys.load(opts)
  end

  defp mode(path) do
    {:ok, stat} = File.stat(path)
    Bitwise.band(stat.mode, 0o777)
  end
end
