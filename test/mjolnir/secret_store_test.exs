defmodule Mjolnir.SecretStoreTest do
  use ExUnit.Case, async: false

  alias Mjolnir.SecretStore
  alias Mjolnir.Aie.Offer
  alias Mjolnir.Sites.{HeadRecord, IdentiKey}

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("mjolnir-secretstore-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    original = Application.get_env(:mjolnir, :secret_store_root)
    Application.put_env(:mjolnir, :secret_store_root, tmp)

    on_exit(fn ->
      Application.put_env(:mjolnir, :secret_store_root, original)
      File.rm_rf!(tmp)
    end)

    keypair = IdentiKey.gen_keypair()
    fp = IdentiKey.fingerprint(keypair)
    :ok = SecretStore.put(fp, "identity/pubkey", identity_record(keypair))

    {:ok, keypair: keypair, fp: fp, tmp: tmp}
  end

  defp identity_record(keypair) do
    Jason.encode!(%{"pubkey" => Base.encode64(keypair.ed25519_public)})
  end

  defp signed_head(keypair, fp, key \\ "sites/blog/HEAD", seq \\ 1) do
    head = %HeadRecord{
      version: 1,
      identikey_fp: fp,
      site_name: "blog",
      snapshot_hash: "hash-#{seq}",
      sequence: seq,
      created_at: ~U[2026-05-13 12:00:00Z],
      signature: nil
    }

    signing_bytes = HeadRecord.canonical_signing_bytes(head)
    sig = IdentiKey.sign(keypair, signing_bytes)
    signed = %{head | signature: sig}

    {key, HeadRecord.serialize(signed)}
  end

  test "put/get round-trips bytes", %{keypair: kp, fp: fp} do
    {key, envelope} = signed_head(kp, fp)
    assert :ok = SecretStore.put(fp, key, envelope)
    assert {:ok, ^envelope} = SecretStore.get(fp, key)
  end

  test "get on missing key returns :not_found", %{fp: fp} do
    assert :not_found = SecretStore.get(fp, "sites/does-not-exist/HEAD")
  end

  test "list returns records under a prefix", %{keypair: kp, fp: fp, tmp: _tmp} do
    {_, env_a} = signed_head(kp, fp, "sites/blog/HEAD", 1)
    {_, env_b} = signed_head(kp, fp, "sites/blog/config", 2)
    {_, env_c} = signed_head(kp, fp, "sites/other/HEAD", 3)

    :ok = SecretStore.put(fp, "sites/blog/HEAD", env_a)
    :ok = SecretStore.put(fp, "sites/blog/config", env_b)
    :ok = SecretStore.put(fp, "sites/other/HEAD", env_c)

    blog = SecretStore.list(fp, "sites/blog")
    assert "sites/blog/HEAD" in blog
    assert "sites/blog/config" in blog
    refute "sites/other/HEAD" in blog
  end

  test "rejects path traversal in keys", %{fp: fp} do
    assert_raise ArgumentError, fn ->
      SecretStore.put(fp, "../escape", "x")
    end

    assert_raise ArgumentError, fn ->
      SecretStore.put(fp, "/abs", "x")
    end
  end

  test "rejects bogus fingerprints" do
    assert_raise ArgumentError, fn ->
      SecretStore.put("not/safe", "k", "x")
    end
  end

  test "delete removes the record", %{keypair: kp, fp: fp} do
    {key, envelope} = signed_head(kp, fp)
    :ok = SecretStore.put(fp, key, envelope)
    assert {:ok, ^envelope} = SecretStore.get(fp, key)
    # Tombstone is also a signed envelope
    {_, tombstone} = signed_head(kp, fp, key, 99)
    :ok = SecretStore.delete(fp, key, tombstone)
    assert :not_found = SecretStore.get(fp, key)
  end

  test "empty envelopes are rejected", %{fp: fp} do
    assert {:error, :empty_envelope} = SecretStore.put(fp, "k", "")
  end

  test "opaque put/get/delete is path-safe and mode 0600", %{tmp: tmp} do
    assert :ok = SecretStore.put_opaque("vms", "vm-1", "identity", "nsec-bytes")
    assert {:ok, "nsec-bytes"} = SecretStore.get_opaque("vms", "vm-1", "identity")

    path = Path.join([tmp, "_opaque", "vms", "vm-1", "identity"])
    %File.Stat{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o600

    assert {:error, :invalid_opaque_id} = SecretStore.put_opaque("vms", "../x", "k", "b")
    assert {:error, :invalid_opaque_key} = SecretStore.put_opaque("vms", "vm-1", "a/b", "b")

    assert :ok = SecretStore.delete_opaque("vms", "vm-1", "identity")
    assert :not_found = SecretStore.get_opaque("vms", "vm-1", "identity")
    assert :ok = SecretStore.delete_opaque_id("vms", "vm-1")
  end

  defp signed_offer(keypair, fp, attrs \\ []) do
    offer = %Offer{
      version: 1,
      owner_fp: fp,
      offer_id: Keyword.get(attrs, :offer_id, "npu"),
      vm_id: Keyword.get(attrs, :vm_id, "vm-1"),
      being_pubkey: keypair.ed25519_public,
      sequence: Keyword.get(attrs, :sequence, 1),
      guild: Keyword.get(attrs, :guild, nil),
      design_ids: Keyword.get(attrs, :design_ids, ["npu2"]),
      max_wall_time: Keyword.get(attrs, :max_wall_time, 30),
      tombstone: Keyword.get(attrs, :tombstone, false),
      signature: nil
    }

    Offer.serialize(Offer.sign(offer, keypair))
  end

  test "offer leaf sniffs without breaking HEAD put/get", %{keypair: kp, fp: fp} do
    {key, envelope} = signed_head(kp, fp)
    assert :ok = SecretStore.put(fp, key, envelope)

    offer_bytes = signed_offer(kp, fp)
    assert :ok = SecretStore.put(fp, Offer.key("npu"), offer_bytes)
    assert {:ok, ^offer_bytes} = SecretStore.get(fp, Offer.key("npu"))
    assert {:ok, ^envelope} = SecretStore.get(fp, key)
  end

  test "offer sequence floor refuses put at or below current including retired bytes", %{
    keypair: kp,
    fp: fp
  } do
    live = signed_offer(kp, fp, sequence: 1)
    assert :ok = SecretStore.put(fp, Offer.key("npu"), live)
    assert {:error, :sequence_floor} = SecretStore.put(fp, Offer.key("npu"), live)

    tomb = signed_offer(kp, fp, sequence: 2, tombstone: true)
    assert :ok = SecretStore.put(fp, Offer.key("npu"), tomb)
    assert {:ok, ^tomb} = SecretStore.get(fp, Offer.key("npu"))
    assert {:error, :sequence_floor} = SecretStore.put(fp, Offer.key("npu"), live)
    assert {:error, :sequence_floor} = SecretStore.put(fp, Offer.key("npu"), tomb)

    nxt = signed_offer(kp, fp, sequence: 3)
    assert :ok = SecretStore.put(fp, Offer.key("npu"), nxt)
  end

  test "offer delete retains a signed tombstone as the floor", %{keypair: kp, fp: fp} do
    live = signed_offer(kp, fp, sequence: 1)
    assert :ok = SecretStore.put(fp, Offer.key("npu"), live)
    tomb = signed_offer(kp, fp, sequence: 2, tombstone: true)
    assert :ok = SecretStore.delete(fp, Offer.key("npu"), tomb)
    assert {:ok, ^tomb} = SecretStore.get(fp, Offer.key("npu"))
    assert {:error, :sequence_floor} = SecretStore.put(fp, Offer.key("npu"), live)
  end
end
