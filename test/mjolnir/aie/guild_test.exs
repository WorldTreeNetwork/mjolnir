defmodule Mjolnir.Aie.GuildTest do
  use ExUnit.Case, async: false

  alias Mjolnir.Aie.{Delegate, Guild, Offer}
  alias Mjolnir.Aie.Guild.Roster
  alias Mjolnir.AIE.Pending
  alias Mjolnir.Biscuit
  alias Mjolnir.SecretStore
  alias Mjolnir.Sites.IdentiKey

  @grant_hex "6d6a6f6c6e69722f6169652d64656c65676174652f763100000004000000010000000267310000002000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000b6169652d65786563757465000000080000000000000000000000080000000000015180000000080000000000000001"
  @withdraw_hex "6d6a6f6c6e69722f6169652d64656c65676174652d77697468647261772f763100000004000000010000000267310000002000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000c6169652d7769746864726177000000080000000000000000000000080000000000000000000000080000000000000001"

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("mjolnir-aie-guild-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    original_root = Application.get_env(:mjolnir, :secret_store_root)
    original_rosters = Application.get_env(:mjolnir, :aie_guild_rosters)
    original_fetch = Application.get_env(:mjolnir, :aie_roster_fetch)

    Application.put_env(:mjolnir, :secret_store_root, tmp)

    member = IdentiKey.gen_keypair()
    consumer = IdentiKey.gen_keypair()
    authority = IdentiKey.gen_keypair()
    storage_fp = IdentiKey.fingerprint(member)
    holder_fp = Biscuit.holder_fingerprint(consumer.ed25519_public)
    now = System.system_time(:second)

    :ok = SecretStore.put(storage_fp, "identity/pubkey", identity_record(member))

    Application.put_env(:mjolnir, :aie_guild_rosters, %{
      "g1" => %{endpoint: "http://roster.test/g1", authority_pubkey: authority.ed25519_public}
    })

    pending_name = :"guild_pending_#{System.unique_integer([:positive])}"
    pending = start_supervised!({Pending, name: pending_name})

    on_exit(fn ->
      Application.put_env(:mjolnir, :secret_store_root, original_root)
      put_env(:aie_guild_rosters, original_rosters)
      put_env(:aie_roster_fetch, original_fetch)
      File.rm_rf!(tmp)
    end)

    {:ok,
     tmp: tmp,
     member: member,
     consumer: consumer,
     authority: authority,
     storage_fp: storage_fp,
     holder_fp: holder_fp,
     now: now,
     pending: pending}
  end

  defp put_env(key, nil), do: Application.delete_env(:mjolnir, key)
  defp put_env(key, value), do: Application.put_env(:mjolnir, key, value)

  defp identity_record(keypair) do
    Jason.encode!(%{"pubkey" => Base.encode64(keypair.ed25519_public)})
  end

  defp grant(ctx, attrs \\ []) do
    %Delegate{
      type: :grant,
      version: 1,
      guild: Keyword.get(attrs, :guild, "g1"),
      member_pk: Keyword.get(attrs, :member_pk, ctx.member.ed25519_public),
      holder_fp: Keyword.get(attrs, :holder_fp, ctx.holder_fp),
      purpose: Keyword.get(attrs, :purpose, "aie-execute"),
      issued_at: Keyword.get(attrs, :issued_at, ctx.now),
      expires_at: Keyword.get(attrs, :expires_at, ctx.now + 3_600),
      sequence: Keyword.get(attrs, :sequence, 1)
    }
  end

  defp withdraw(ctx, attrs) do
    %Delegate{
      type: :withdraw,
      version: 1,
      guild: Keyword.get(attrs, :guild, "g1"),
      member_pk: Keyword.get(attrs, :member_pk, ctx.member.ed25519_public),
      holder_fp: Keyword.get(attrs, :holder_fp, ctx.holder_fp),
      purpose: "aie-withdraw",
      issued_at: Keyword.get(attrs, :issued_at, ctx.now),
      expires_at: Keyword.get(attrs, :expires_at, 0),
      sequence: Keyword.get(attrs, :sequence, 2)
    }
  end

  defp sample_offer(guild) do
    %Offer{
      version: 1,
      owner_fp: "owner",
      offer_id: "npu",
      vm_id: "vm",
      being_pubkey: :crypto.strong_rand_bytes(32),
      sequence: 1,
      guild: guild,
      design_ids: ["vector-add"],
      max_wall_time: 30,
      tombstone: false
    }
  end

  defp roster_body(ctx, attrs \\ []) do
    guild = Keyword.get(attrs, :guild, "g1")
    member_pk = Keyword.get(attrs, :member_pk, ctx.member.ed25519_public)
    member? = Keyword.get(attrs, :member?, true)
    issued_at = Keyword.get(attrs, :issued_at, ctx.now)
    signer = Keyword.get(attrs, :signer, ctx.authority)
    bytes = Roster.signing_bytes(guild, member_pk, member?, issued_at)
    sig = IdentiKey.sign(signer, bytes)
    Roster.serialize(guild, member_pk, member?, issued_at, sig)
  end

  defp roster_fetch(body) when is_binary(body) do
    fn _cfg, _g, _pk, _opts -> {:ok, body} end
  end

  defp roster_fetch(list) when is_list(list) do
    {:ok, agent} = Agent.start_link(fn -> list end)

    fn _cfg, _g, _pk, _opts ->
      Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> {{:error, :unavailable}, []}
      end)
    end
  end

  defp enqueue(ctx, attrs) do
    nonce = Mjolnir.Secrets.Nonces.issue()
    member_pk = Keyword.get(attrs, :member_pk, ctx.member.ed25519_public)

    frame = %{
      "biscuit_digest" => "bd1",
      "audience" => "mint-root-fp",
      "resource" => "owner/offer/incarnation",
      "design_id" => "vector-add",
      "input_blake3" => "in1",
      "idempotency_key" => "idem-#{System.unique_integer([:positive])}",
      "holder_fp" => Base.encode64(ctx.holder_fp)
    }

    frame =
      if Keyword.get(attrs, :omit_selector, false) do
        frame
      else
        Map.put(frame, "member_pk", Base.encode64(member_pk))
      end

    {:ok, pending_id} = Pending.enqueue(ctx.pending, nonce, frame)
    pending_id
  end

  defp admit_args(ctx, attrs \\ []) do
    %{
      offer: Keyword.get(attrs, :offer, sample_offer("g1")),
      holder_fp: Keyword.get(attrs, :holder_fp, ctx.holder_fp),
      pending_id: Keyword.get(attrs, :pending_id, enqueue(ctx, attrs)),
      attempt_id: Keyword.get(attrs, :attempt_id, "att_live"),
      deadline_mono_ms:
        Keyword.get(attrs, :deadline_mono_ms, System.monotonic_time(:millisecond) + 5_000),
      pending: ctx.pending,
      now: Keyword.get(attrs, :now, ctx.now),
      biscuit_ok: Keyword.get(attrs, :biscuit_ok, true),
      token_member: Keyword.get(attrs, :token_member, false),
      roster_fetch: Keyword.get(attrs, :roster_fetch, roster_fetch(roster_body(ctx)))
    }
  end

  test "unsigned grant and withdraw vectors match the published Redeem fixtures" do
    assert byte_size(Delegate.grant_vector()) == 160
    assert byte_size(Delegate.withdraw_vector()) == 170
    assert Base.encode16(Delegate.grant_vector(), case: :lower) == @grant_hex
    assert Base.encode16(Delegate.withdraw_vector(), case: :lower) == @withdraw_hex
  end

  test "publish and read back through SecretStore", ctx do
    rec = grant(ctx)
    assert :ok = Delegate.put(rec, ctx.member)
    assert {:ok, stored} = Delegate.current(ctx.member.ed25519_public, ctx.holder_fp)
    assert stored.guild == "g1"
    assert stored.member_pk == ctx.member.ed25519_public
    assert stored.holder_fp == ctx.holder_fp
    assert Delegate.canonical_signing_bytes(stored) == Delegate.signing_bytes(rec)

    {:ok, bytes} = SecretStore.get(ctx.storage_fp, Delegate.key(ctx.holder_fp))
    assert :ok = SecretStore.verify_envelope(ctx.storage_fp, bytes)
  end

  test "malformed encoding and wrong type are refused", ctx do
    assert {:error, _} = SecretStore.put(ctx.storage_fp, Delegate.key(ctx.holder_fp), "{not-json")

    rec = grant(ctx)
    signed = Delegate.sign(rec, ctx.member)
    raw = Jason.decode!(Delegate.serialize(signed))
    bad = Jason.encode!(Map.put(raw, "type", "head"))
    assert {:error, _} = SecretStore.put(ctx.storage_fp, Delegate.key(ctx.holder_fp), bad)
  end

  test "wrong-purpose and wrong-namespace puts are refused", ctx do
    assert {:error, :malformed} =
             Delegate.put(grant(ctx, purpose: "aie-withdraw"), ctx.member)

    other = IdentiKey.gen_keypair()
    other_fp = IdentiKey.fingerprint(other)
    :ok = SecretStore.put(other_fp, "identity/pubkey", identity_record(other))

    rec = Delegate.sign(grant(ctx), other)

    assert {:error, :wrong_namespace} =
             SecretStore.put(other_fp, Delegate.key(ctx.holder_fp), Delegate.serialize(rec))
  end

  test "guild member runs; stranger is fail-closed", ctx do
    assert :ok = Delegate.put(grant(ctx), ctx.member)
    assert :ok = Guild.admit(admit_args(ctx))

    stranger = IdentiKey.gen_keypair()
    pending_id = enqueue(ctx, member_pk: stranger.ed25519_public)

    assert {:error, reason} =
             Guild.admit(
               admit_args(ctx, pending_id: pending_id, member_pk: stranger.ed25519_public)
             )

    assert reason in [:no_delegation, :not_member, :unconfigured, :member_mismatch]
  end

  test "personal-fp offers skip lookup and delegation", ctx do
    flunk_fetch = fn _, _, _, _ -> flunk("roster must not run for personal offers") end

    assert :ok =
             Guild.admit(
               admit_args(ctx,
                 offer: sample_offer(nil),
                 omit_selector: true,
                 roster_fetch: flunk_fetch
               )
             )
  end

  test "mint/authorize stay inject_holder; token member fact is ignored", ctx do
    biscuit = File.read!("lib/mjolnir/biscuit.ex")
    refute biscuit =~ "member("
    refute biscuit =~ "inject_member"
    assert biscuit =~ "inject_holder"

    assert :ok = Delegate.put(grant(ctx), ctx.member)

    assert {:error, :not_member} =
             Guild.admit(
               admit_args(ctx,
                 token_member: true,
                 biscuit_ok: true,
                 roster_fetch: roster_fetch(roster_body(ctx, member?: false))
               )
             )
  end

  test "biscuit alone does not admit a guild offer", ctx do
    assert {:error, :no_delegation} =
             Guild.admit(admit_args(ctx, biscuit_ok: true))
  end

  test "missing selector is refused", ctx do
    assert :ok = Delegate.put(grant(ctx), ctx.member)

    assert {:error, :missing_selector} =
             Guild.admit(admit_args(ctx, omit_selector: true))
  end

  test "forged or wrong-member selector is refused", ctx do
    assert :ok = Delegate.put(grant(ctx), ctx.member)
    other = IdentiKey.gen_keypair()
    other_fp = IdentiKey.fingerprint(other)
    :ok = SecretStore.put(other_fp, "identity/pubkey", identity_record(other))

    pending_id = enqueue(ctx, member_pk: other.ed25519_public)

    assert {:error, reason} =
             Guild.admit(admit_args(ctx, pending_id: pending_id, member_pk: other.ed25519_public))

    assert reason in [:no_delegation, :member_mismatch]
  end

  test "bad signature, wrong holder, and cross-guild leaves are refused", ctx do
    rec = Delegate.sign(grant(ctx), ctx.member)
    raw = Jason.decode!(Delegate.serialize(rec))
    raw = put_in(raw, ["signature", "ed25519"], Base.encode64(:crypto.strong_rand_bytes(64)))
    path = Path.join([SecretStore.root(), ctx.storage_fp, Delegate.key(ctx.holder_fp)])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(raw))

    assert {:error, :malformed} = Delegate.current(ctx.member.ed25519_public, ctx.holder_fp)

    File.rm!(path)
    assert :ok = Delegate.put(grant(ctx), ctx.member)

    other_holder = Biscuit.holder_fingerprint(IdentiKey.gen_keypair().ed25519_public)

    assert {:error, :holder_mismatch} =
             Delegate.authorize_grant(
               Delegate.sign(grant(ctx), ctx.member),
               "g1",
               ctx.member.ed25519_public,
               other_holder,
               ctx.now
             )

    assert {:error, :cross_guild} =
             Delegate.authorize_grant(
               Delegate.sign(grant(ctx, guild: "g1"), ctx.member),
               "g2",
               ctx.member.ed25519_public,
               ctx.holder_fp,
               ctx.now
             )
  end

  test "expired leaf is refused at admission", ctx do
    rec = grant(ctx, issued_at: ctx.now - 100, expires_at: ctx.now - 1)
    assert :ok = Delegate.put(rec, ctx.member)
    assert {:error, :expired} = Guild.admit(admit_args(ctx))
  end

  test "authorized withdrawal succeeds and cannot be replayed as a grant", ctx do
    assert :ok = Delegate.put(grant(ctx), ctx.member)
    assert :ok = Delegate.put(withdraw(ctx, sequence: 2), ctx.member)
    assert {:error, :tombstoned} = Guild.admit(admit_args(ctx))

    assert {:error, :sequence_floor} = Delegate.put(grant(ctx, sequence: 1), ctx.member)
    assert {:error, :sequence_floor} = Delegate.put(withdraw(ctx, sequence: 2), ctx.member)
  end

  test "grant signature cannot withdraw; tombstone cannot admit", ctx do
    signed_grant = Delegate.sign(grant(ctx, sequence: 2), ctx.member)
    assert :ok = Delegate.put(grant(ctx, sequence: 1), ctx.member)

    raw = Jason.decode!(Delegate.serialize(signed_grant))
    withdrawn = Map.merge(raw, %{"type" => "aie_delegate_withdraw", "purpose" => "aie-withdraw"})

    assert {:error, :bad_signature} =
             SecretStore.put(
               ctx.storage_fp,
               Delegate.key(ctx.holder_fp),
               Jason.encode!(withdrawn)
             )

    assert :ok = Delegate.put(withdraw(ctx, sequence: 2), ctx.member)
    {:ok, rec} = Delegate.current(ctx.member.ed25519_public, ctx.holder_fp)
    assert rec.type == :withdraw
    assert {:error, :tombstoned} = Guild.admit(admit_args(ctx))
  end

  test "wrong-target withdrawal is refused", ctx do
    assert :ok = Delegate.put(grant(ctx), ctx.member)
    other_holder = Biscuit.holder_fingerprint(IdentiKey.gen_keypair().ed25519_public)
    tomb = Delegate.sign(withdraw(ctx, holder_fp: other_holder, sequence: 2), ctx.member)

    assert {:error, :delegate_key_mismatch} =
             SecretStore.put(
               ctx.storage_fp,
               Delegate.key(ctx.holder_fp),
               Delegate.serialize(tomb)
             )
  end

  test "stale tombstone cannot withdraw a regrant", ctx do
    assert :ok = Delegate.put(grant(ctx, sequence: 1), ctx.member)
    assert :ok = Delegate.put(withdraw(ctx, sequence: 2), ctx.member)

    assert :ok =
             Delegate.put(
               grant(ctx, sequence: 3, issued_at: ctx.now, expires_at: ctx.now + 60),
               ctx.member
             )

    assert {:error, :sequence_floor} = Delegate.put(withdraw(ctx, sequence: 2), ctx.member)
    assert :ok = Guild.admit(admit_args(ctx))
  end

  test "rollback after replacement and floor after restart are refused", ctx do
    first = grant(ctx, sequence: 1)
    assert :ok = Delegate.put(first, ctx.member)
    assert :ok = Delegate.put(grant(ctx, sequence: 2), ctx.member)
    assert {:error, :sequence_floor} = Delegate.put(first, ctx.member)

    {:ok, bytes} = SecretStore.get(ctx.storage_fp, Delegate.key(ctx.holder_fp))
    # Restart is a new BEAM read of the same record.
    assert {:ok, ^bytes} = SecretStore.get(ctx.storage_fp, Delegate.key(ctx.holder_fp))
    assert {:error, :sequence_floor} = Delegate.put(first, ctx.member)
  end

  test "generic delete and sequence-1 put cannot reset the floor", ctx do
    assert :ok = Delegate.put(grant(ctx, sequence: 1), ctx.member)
    assert :ok = Delegate.put(withdraw(ctx, sequence: 2), ctx.member)

    tomb = Delegate.serialize(Delegate.sign(withdraw(ctx, sequence: 3), ctx.member))

    assert {:error, :delegate_delete_forbidden} =
             SecretStore.delete(ctx.storage_fp, Delegate.key(ctx.holder_fp), tomb)

    assert {:error, :sequence_floor} = Delegate.put(grant(ctx, sequence: 1), ctx.member)
    {:ok, rec} = Delegate.current(ctx.member.ed25519_public, ctx.holder_fp)
    assert rec.sequence == 2
  end

  test "interrupted withdrawal leaves the previous snapshot", ctx do
    assert :ok = Delegate.put(grant(ctx), ctx.member)
    path = Path.join([SecretStore.root(), ctx.storage_fp, Delegate.key(ctx.holder_fp)])
    tomb = Delegate.serialize(Delegate.sign(withdraw(ctx, sequence: 2), ctx.member))
    File.write!(path <> ".tmp", tomb)

    assert :ok = Guild.admit(admit_args(ctx))
    File.rename!(path <> ".tmp", path)
    assert {:error, :tombstoned} = Guild.admit(admit_args(ctx))
  end

  test "partial or corrupt current bytes fail closed", ctx do
    assert :ok = Delegate.put(grant(ctx), ctx.member)
    path = Path.join([SecretStore.root(), ctx.storage_fp, Delegate.key(ctx.holder_fp)])
    File.write!(path, "not-a-delegate")

    assert {:error, :malformed} = Guild.admit(admit_args(ctx))
    assert {:error, :corrupt_current} = Delegate.put(grant(ctx, sequence: 2), ctx.member)
  end

  test "unconfigured guild, timeout, malformed, stale, future, and wrong-subject fail closed",
       ctx do
    assert :ok = Delegate.put(grant(ctx), ctx.member)

    previous = Application.get_env(:mjolnir, :aie_guild_rosters)
    Application.put_env(:mjolnir, :aie_guild_rosters, %{})

    assert {:error, :unconfigured} =
             Guild.admit(admit_args(ctx, roster_fetch: fn _, _, _, _ -> {:ok, "{}"} end))

    Application.put_env(:mjolnir, :aie_guild_rosters, previous)

    assert {:error, :unavailable} =
             Guild.admit(
               admit_args(ctx, roster_fetch: fn _, _, _, _ -> {:error, :unavailable} end)
             )

    assert {:error, :malformed} =
             Guild.admit(admit_args(ctx, roster_fetch: roster_fetch("not-json")))

    other = IdentiKey.gen_keypair()

    assert {:error, :unauthenticated} =
             Guild.admit(
               admit_args(ctx, roster_fetch: roster_fetch(roster_body(ctx, signer: other)))
             )

    assert {:error, :wrong_subject} =
             Guild.admit(
               admit_args(ctx,
                 roster_fetch: roster_fetch(roster_body(ctx, member_pk: other.ed25519_public))
               )
             )

    assert {:error, :stale} =
             Guild.admit(
               admit_args(ctx,
                 roster_fetch: roster_fetch(roster_body(ctx, issued_at: ctx.now - 120))
               )
             )

    assert {:error, :future} =
             Guild.admit(
               admit_args(ctx,
                 roster_fetch: roster_fetch(roster_body(ctx, issued_at: ctx.now + 30))
               )
             )
  end

  test "fresh negative overrides enqueue-time positive", ctx do
    assert :ok = Delegate.put(grant(ctx), ctx.member)

    fetch =
      roster_fetch([
        {:ok, roster_body(ctx, member?: true)},
        {:ok, roster_body(ctx, member?: false)}
      ])

    args = admit_args(ctx, roster_fetch: fetch)
    assert :ok = Guild.admit(args)
    assert {:error, :not_member} = Guild.admit(args)
  end

  test "abandoned-attempt success is unusable after the deadline", ctx do
    assert :ok = Delegate.put(grant(ctx), ctx.member)

    assert {:error, :deadline} =
             Guild.admit(
               admit_args(ctx,
                 deadline_mono_ms: System.monotonic_time(:millisecond) - 1
               )
             )
  end

  test "missing guild gate does not return ok", ctx do
    # No current leaf, no roster success: sidecar must not load.
    assert {:error, _} = Guild.admit(admit_args(ctx, biscuit_ok: true))
  end
end
