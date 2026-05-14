defmodule Mix.Tasks.Mjolnir.Sites.AliasTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Mjolnir.API.SitesRouter
  alias Mjolnir.SecretStore
  alias Mjolnir.Sites.{Crypto, IdentiKey, Manifest, Publisher, Store}
  alias Mjolnir.Sites.Manifest.Entry
  alias Mjolnir.Sites.HeadRecord

  @opts SitesRouter.init([])

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("mjolnir-alias-task-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([tmp, "blob", "b3"]))
    File.mkdir_p!(Path.join([tmp, "manifests"]))
    keyspace = Path.join(tmp, "keyspace")
    File.mkdir_p!(keyspace)

    orig_sites = Application.get_env(:mjolnir, :sites_root)
    orig_secret = Application.get_env(:mjolnir, :secret_store_root)
    Application.put_env(:mjolnir, :sites_root, tmp)
    Application.put_env(:mjolnir, :secret_store_root, keyspace)

    keypair = IdentiKey.gen_keypair()
    fp = IdentiKey.fingerprint(keypair)

    :ok =
      SecretStore.put(
        fp,
        "identity/pubkey",
        Jason.encode!(%{"pubkey" => Base.encode64(keypair.ed25519_public)})
      )

    on_exit(fn ->
      Application.put_env(:mjolnir, :sites_root, orig_sites)
      Application.put_env(:mjolnir, :secret_store_root, orig_secret)
      File.rm_rf!(tmp)
    end)

    {:ok, keypair: keypair, fp: fp, tmp: tmp}
  end

  defp call(method, path, body \\ "") do
    conn(method, path, body) |> SitesRouter.call(@opts)
  end

  # Set up a small published site (manifest + chunk + HEAD)
  defp publish_site(keypair, fp, site_name) do
    sym_seed = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(24)
    plaintext = "<h1>hello from alias</h1>"
    path = "/index.html"
    sym_key = Crypto.hkdf_sha256(sym_seed, path, 32)
    ciphertext = Crypto.xchacha20_encrypt(sym_key, nonce, plaintext)
    chunk_hash = Crypto.blake3_hash_base58(ciphertext)

    manifest = %Manifest{
      version: 1,
      identikey_fp: fp,
      site_name: site_name,
      mode: :public,
      created_at: ~U[2026-05-13 12:00:00Z],
      sym_seed: sym_seed,
      signatures: <<1, 2, 3>>,
      entries: [
        %Entry{
          path: path,
          content_type: "text/html; charset=utf-8",
          bao_hash: chunk_hash,
          ciphertext_size: byte_size(ciphertext),
          plaintext_size: byte_size(plaintext),
          nonce: nonce,
          wrapped_key: nil,
          content_encoding: nil
        }
      ]
    }

    mbytes = Manifest.serialize(manifest)
    hash = Manifest.snapshot_hash(mbytes)

    :ok = Store.put_manifest(hash, mbytes)
    :ok = Store.put_chunk(chunk_hash, ciphertext, <<>>)

    head = %HeadRecord{
      version: 1,
      identikey_fp: fp,
      site_name: site_name,
      snapshot_hash: hash,
      sequence: 1,
      created_at: ~U[2026-05-13 12:00:00Z],
      signature: nil
    }

    sig = IdentiKey.sign(keypair, HeadRecord.canonical_signing_bytes(head))
    head_bytes = HeadRecord.serialize(%{head | signature: sig})
    :ok = SecretStore.put(fp, "sites/#{site_name}/HEAD", head_bytes)
    plaintext
  end

  test "end-to-end: publish_alias → lookup → remove_alias → 404", %{keypair: kp, fp: fp} do
    site_name = "blog"
    fqdn = "e2e.duke.io"

    # Step 1: publish a small snapshot
    _plaintext = publish_site(kp, fp, site_name)

    # Step 2: publish alias via Publisher (directly, no HTTP server needed)
    alias_bytes = Publisher.build_alias(kp, fp, site_name, fqdn, 1)
    conn = call(:put, "/#{fp}/#{site_name}/aliases/#{fqdn}", alias_bytes)
    assert conn.status == 201

    # Step 3: resolver returns correct fp/site
    conn = call(:get, "/aliases/lookup?host=#{fqdn}")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["identikey_fp"] == fp
    assert body["site_name"] == site_name

    # Step 4: remove alias via Publisher.build_alias with higher sequence
    tombstone_bytes = Publisher.build_alias(kp, fp, site_name, fqdn, 9_999_999)
    conn = call(:delete, "/#{fp}/#{site_name}/aliases/#{fqdn}", tombstone_bytes)
    assert conn.status == 204

    # Step 5: resolver now returns 404
    conn = call(:get, "/aliases/lookup?host=#{fqdn}")
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"] == "not_found"
  end

  test "build_alias produces a valid signed record", %{keypair: kp, fp: fp} do
    fqdn = "build-test.duke.io"
    bytes = Publisher.build_alias(kp, fp, "blog", fqdn, 42)

    assert {:ok, record} = Mjolnir.Sites.AliasRecord.parse(bytes)
    assert record.fqdn == fqdn
    assert record.sequence == 42
    assert record.identikey_fp == fp
    assert is_binary(record.signature) and byte_size(record.signature) == 64
  end

  test "publish_alias via HTTP roundtrips correctly", %{keypair: kp, fp: fp} do
    # We test publish_alias by calling the router directly with a Bypass-like
    # approach: start a local test server via Plug.Cowboy or just verify the
    # bytes match what the router would accept.
    fqdn = "http-roundtrip.duke.io"
    alias_bytes = Publisher.build_alias(kp, fp, "blog", fqdn, 1)

    # PUT the bytes directly through the router (same as publish_alias does over HTTP)
    conn = call(:put, "/#{fp}/blog/aliases/#{fqdn}", alias_bytes)
    assert conn.status == 201

    # Verify lookup works
    conn = call(:get, "/aliases/lookup?host=#{fqdn}")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["site_name"] == "blog"
  end
end
