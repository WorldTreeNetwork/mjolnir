defmodule Mjolnir.Sites.AliasSecretStoreTest do
  use ExUnit.Case, async: false

  alias Mjolnir.SecretStore
  alias Mjolnir.Sites.{AliasRecord, IdentiKey}

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("mjolnir-alias-store-test-#{System.unique_integer([:positive])}")

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

  defp signed_alias(keypair, fp, site_name, fqdn, seq \\ 1) do
    record = %AliasRecord{
      version: 1,
      identikey_fp: fp,
      site_name: site_name,
      fqdn: fqdn,
      sequence: seq,
      created_at: DateTime.utc_now() |> DateTime.truncate(:second),
      signature: nil
    }

    signing_bytes = AliasRecord.canonical_signing_bytes(record)
    sig = IdentiKey.sign(keypair, signing_bytes)
    signed = %{record | signature: sig}
    AliasRecord.serialize(signed)
  end

  test "putting an alias record creates index entry", %{keypair: kp, fp: fp} do
    fqdn = "blog.duke.io"
    bytes = signed_alias(kp, fp, "blog", fqdn)
    :ok = SecretStore.put(fp, "sites/blog/aliases/#{fqdn}", bytes)

    assert {:ok, {^fp, "blog"}} = SecretStore.lookup_alias(fqdn)
  end

  test "deleting an alias record removes index entry", %{keypair: kp, fp: fp} do
    fqdn = "news.duke.io"
    bytes = signed_alias(kp, fp, "news", fqdn, 1)
    :ok = SecretStore.put(fp, "sites/news/aliases/#{fqdn}", bytes)
    assert {:ok, {^fp, "news"}} = SecretStore.lookup_alias(fqdn)

    tombstone = signed_alias(kp, fp, "news", fqdn, 2)
    :ok = SecretStore.delete(fp, "sites/news/aliases/#{fqdn}", tombstone)
    assert :not_found = SecretStore.lookup_alias(fqdn)
  end

  test "lookup_alias returns :not_found for unknown fqdn" do
    assert :not_found = SecretStore.lookup_alias("unknown.example.com")
  end

  test "alias record with bad signature is rejected", %{fp: fp} do
    fqdn = "bad.duke.io"
    # Sign with a different keypair so verification fails
    other_kp = IdentiKey.gen_keypair()
    bytes = signed_alias(other_kp, fp, "blog", fqdn)

    assert {:error, :bad_signature} = SecretStore.put(fp, "sites/blog/aliases/#{fqdn}", bytes)
    assert :not_found = SecretStore.lookup_alias(fqdn)
  end

  test "alias index write is durable on disk", %{keypair: kp, fp: fp, tmp: tmp} do
    fqdn = "persist.duke.io"
    bytes = signed_alias(kp, fp, "blog", fqdn)
    :ok = SecretStore.put(fp, "sites/blog/aliases/#{fqdn}", bytes)

    # The index file should exist on disk right after the put
    index_path = Path.join([tmp, "_index", "aliases", fqdn])
    assert File.exists?(index_path)
    assert Jason.decode!(File.read!(index_path)) == %{"fp" => fp, "site" => "blog"}

    # Deleting the index manually makes lookup miss
    File.rm!(index_path)
    assert :not_found = SecretStore.lookup_alias(fqdn)

    # Rebuild the index in a fresh (unnamed) process using the same root dir
    {:ok, pid} = :gen_server.start(SecretStore, [], [])
    # init/1 ran rebuild_alias_index, so the index file should be back
    assert File.exists?(index_path)
    assert Jason.decode!(File.read!(index_path)) == %{"fp" => fp, "site" => "blog"}
    GenServer.stop(pid)

    # Now lookup via the live global store reads the restored file
    assert {:ok, {^fp, "blog"}} = SecretStore.lookup_alias(fqdn)
  end
end
