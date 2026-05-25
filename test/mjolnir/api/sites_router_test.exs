defmodule Mjolnir.API.SitesRouterTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Mjolnir.API.SitesRouter
  alias Mjolnir.SecretStore
  alias Mjolnir.Sites.{HeadRecord, IdentiKey, Manifest}
  alias Mjolnir.Sites.Manifest.Entry

  @opts SitesRouter.init([])

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("mjolnir-sites-router-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([tmp, "blob", "b3"]))
    File.mkdir_p!(Path.join([tmp, "manifests"]))
    keyspace = Path.join(tmp, "keyspace")
    File.mkdir_p!(keyspace)

    orig_sites = Application.get_env(:mjolnir, :sites_root)
    orig_secret = Application.get_env(:mjolnir, :secret_store_root)
    Application.put_env(:mjolnir, :sites_root, tmp)
    Application.put_env(:mjolnir, :secret_store_root, keyspace)

    # Generate a keypair and register its identity for the default fp
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

    {:ok, tmp: tmp, keypair: keypair, fp: fp}
  end

  defp call(method, path, body \\ "") do
    conn(method, path, body) |> SitesRouter.call(@opts)
  end

  # Build a manifest using the real fp from the setup keypair.
  defp sample_manifest(fp, name \\ "blog") do
    %Manifest{
      version: 1,
      identikey_fp: fp,
      site_name: name,
      mode: :public,
      created_at: ~U[2026-05-13 12:00:00Z],
      sym_seed: :crypto.strong_rand_bytes(32),
      entries: [
        %Entry{
          path: "/index.html",
          content_type: "text/html; charset=utf-8",
          bao_hash: "blakeishhashabc",
          ciphertext_size: 11,
          plaintext_size: 11,
          nonce: :crypto.strong_rand_bytes(24),
          wrapped_key: nil,
          content_encoding: nil
        }
      ],
      signatures: <<1, 2, 3>>
    }
  end

  # Build a *signed* HEAD record serialized to bytes.
  defp signed_head_bytes(keypair, manifest_bytes, fp, name, seq) do
    head = %HeadRecord{
      version: 1,
      identikey_fp: fp,
      site_name: name,
      snapshot_hash: Manifest.snapshot_hash(manifest_bytes),
      sequence: seq,
      created_at: ~U[2026-05-13 12:00:00Z],
      signature: nil
    }

    signing_bytes = HeadRecord.canonical_signing_bytes(head)
    sig = IdentiKey.sign(keypair, signing_bytes)
    %{head | signature: sig} |> HeadRecord.serialize()
  end

  defp frame_chunk(ct, ob) do
    <<byte_size(ct)::big-unsigned-64, ct::binary, byte_size(ob)::big-unsigned-64, ob::binary>>
  end

  test "POST /:fp/:name/snapshot stores manifest and reports missing chunks", %{fp: fp} do
    m = sample_manifest(fp)
    bytes = Manifest.serialize(m)

    conn = call(:post, "/#{fp}/blog/snapshot", bytes)
    assert conn.status == 201
    decoded = Jason.decode!(conn.resp_body)
    assert is_binary(decoded["snapshot_hash"])
    assert decoded["missing_chunks"] == ["blakeishhashabc"]
    assert decoded["ots_status"] in ["submitted", "skipped_unavailable", "failed"]
  end

  test "POST snapshot rejects identikey mismatch", %{fp: fp} do
    other_kp = IdentiKey.gen_keypair()
    other_fp = IdentiKey.fingerprint(other_kp)
    m = sample_manifest(other_fp, "blog")
    bytes = Manifest.serialize(m)

    conn = call(:post, "/#{fp}/blog/snapshot", bytes)
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "identikey_mismatch"
  end

  test "POST snapshot rejects bad manifest bytes", %{fp: fp} do
    conn = call(:post, "/#{fp}/blog/snapshot", "not json")
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "bad_manifest"
  end

  test "PUT /blob/:hash + GET /blob/:hash round-trips ciphertext and outboard" do
    ct = "ciphertext!"
    ob = "outboard!"
    hash = Mjolnir.Sites.Crypto.blake3_hash_base58(ct)
    framed = frame_chunk(ct, ob)

    conn = call(:put, "/blob/#{hash}", framed)
    assert conn.status == 201

    conn = call(:get, "/blob/#{hash}")
    assert conn.status == 200
    assert conn.resp_body == ct

    conn = call(:get, "/blob/#{hash}/outboard")
    assert conn.status == 200
    assert conn.resp_body == ob
  end

  test "PUT /blob/:hash rejects malformed framing" do
    conn = call(:put, "/blob/anyhash", "not framed")
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "bad_framing"
  end

  test "PUT /blob/:hash rejects bao_hash mismatch" do
    framed = frame_chunk("ciphertext-A", "ob")
    conn = call(:put, "/blob/wrongHash", framed)
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] =~ "bao_mismatch"
  end

  test "POST /:fp/:name/head accepts and rejects regressions", %{keypair: kp, fp: fp} do
    m = sample_manifest(fp)
    mbytes = Manifest.serialize(m)
    _ = call(:post, "/#{fp}/blog/snapshot", mbytes)

    head1 = signed_head_bytes(kp, mbytes, fp, "blog", 1)
    head2 = signed_head_bytes(kp, mbytes, fp, "blog", 2)

    conn = call(:post, "/#{fp}/blog/head", head1)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["sequence"] == 1

    conn = call(:post, "/#{fp}/blog/head", head2)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["sequence"] == 2

    # Regression
    conn = call(:post, "/#{fp}/blog/head", head1)
    assert conn.status == 409
    assert Jason.decode!(conn.resp_body)["error"] == "sequence_regression"
  end

  test "GET /:fp/:name/head returns 404 when no HEAD exists", %{fp: fp} do
    conn = call(:get, "/#{fp}/blog/head")
    assert conn.status == 404
  end

  test "GET /manifests/:hash returns stored manifest", %{fp: fp} do
    m = sample_manifest(fp)
    mbytes = Manifest.serialize(m)
    {:ok, %{"snapshot_hash" => hash}} =
      call(:post, "/#{fp}/blog/snapshot", mbytes).resp_body |> Jason.decode()

    conn = call(:get, "/manifests/#{hash}")
    assert conn.status == 200
    assert conn.resp_body == mbytes
  end

  test "PUT + GET /manifests/:hash/ots round-trips" do
    receipt = "fake-ots-receipt-bytes"
    conn = call(:put, "/manifests/somehash/ots", receipt)
    assert conn.status == 201

    conn = call(:get, "/manifests/somehash/ots")
    assert conn.status == 200
    assert conn.resp_body == receipt
  end

  test "end-to-end: publish + serve via debug endpoint", %{keypair: kp, fp: fp} do
    alias Mjolnir.Sites.Crypto

    sym_seed = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(24)
    plaintext_body = "<html>hello</html>"
    path = "/index.html"

    sym_key = Crypto.hkdf_sha256(sym_seed, path, 32)
    ciphertext = Crypto.xchacha20_encrypt(sym_key, nonce, plaintext_body)
    chunk_hash = Crypto.blake3_hash_base58(ciphertext)

    m = %Manifest{
      version: 1,
      identikey_fp: fp,
      site_name: "blog",
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
          plaintext_size: byte_size(plaintext_body),
          nonce: nonce,
          wrapped_key: nil,
          content_encoding: nil
        }
      ]
    }

    mbytes = Manifest.serialize(m)
    {:ok, %{"snapshot_hash" => _}} =
      call(:post, "/#{fp}/blog/snapshot", mbytes).resp_body |> Jason.decode()

    framed = frame_chunk(ciphertext, "outboard-bytes")
    assert 201 == call(:put, "/blob/#{chunk_hash}", framed).status

    head = signed_head_bytes(kp, mbytes, fp, "blog", 1)
    assert 200 == call(:post, "/#{fp}/blog/head", head).status

    conn = call(:get, "/#{fp}/blog/files/index.html")
    assert conn.status == 200
    assert conn.resp_body == plaintext_body
    assert {"content-type", "text/html; charset=utf-8"} in conn.resp_headers
  end

  test "serve trailing slash falls back to index.html", %{keypair: kp, fp: fp} do
    alias Mjolnir.Sites.Crypto

    sym_seed = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(24)
    plaintext_body = "<h1>root</h1>"
    path = "/index.html"
    sym_key = Crypto.hkdf_sha256(sym_seed, path, 32)
    ciphertext = Crypto.xchacha20_encrypt(sym_key, nonce, plaintext_body)
    chunk_hash = Crypto.blake3_hash_base58(ciphertext)

    m = %Manifest{
      version: 1,
      identikey_fp: fp,
      site_name: "blog",
      mode: :public,
      created_at: ~U[2026-05-13 12:00:00Z],
      sym_seed: sym_seed,
      signatures: <<1, 2, 3>>,
      entries: [
        %Entry{
          path: "/index.html",
          content_type: "text/html",
          bao_hash: chunk_hash,
          ciphertext_size: byte_size(ciphertext),
          plaintext_size: byte_size(plaintext_body),
          nonce: nonce,
          wrapped_key: nil,
          content_encoding: nil
        }
      ]
    }

    mbytes = Manifest.serialize(m)
    _ = call(:post, "/#{fp}/blog/snapshot", mbytes)
    _ = call(:put, "/blob/#{chunk_hash}", frame_chunk(ciphertext, "ob"))
    _ = call(:post, "/#{fp}/blog/head", signed_head_bytes(kp, mbytes, fp, "blog", 1))

    conn = call(:get, "/#{fp}/blog/files/")
    assert conn.status == 200
    assert conn.resp_body == plaintext_body
  end

  ## T3: Alias resolver

  test "GET /aliases/lookup returns 200 with fp and site when alias exists", %{keypair: kp, fp: fp} do
    fqdn = "blog.duke.io"
    alias_bytes = signed_alias_bytes(kp, fp, "blog", fqdn)
    assert 201 == call(:put, "/#{fp}/blog/aliases/#{fqdn}", alias_bytes).status

    conn = call(:get, "/aliases/lookup?host=#{fqdn}")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["identikey_fp"] == fp
    assert body["site_name"] == "blog"
  end

  test "GET /aliases/lookup returns 404 for unknown host" do
    conn = call(:get, "/aliases/lookup?host=unknown.example.com")
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"] == "not_found"
  end

  test "GET /aliases/lookup returns 400 when host param is missing" do
    conn = call(:get, "/aliases/lookup")
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "missing_host"
  end

  test "GET /aliases/lookup returns 400 when host param is empty" do
    conn = call(:get, "/aliases/lookup?host=")
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "missing_host"
  end

  ## T4: Alias upload + tombstone

  test "PUT /:fp/:name/aliases/:fqdn stores alias and returns 201", %{keypair: kp, fp: fp} do
    fqdn = "mysite.example.com"
    alias_bytes = signed_alias_bytes(kp, fp, "blog", fqdn)

    conn = call(:put, "/#{fp}/blog/aliases/#{fqdn}", alias_bytes)
    assert conn.status == 201
    assert Jason.decode!(conn.resp_body)["ok"] == true
  end

  test "PUT alias rejects identikey mismatch", %{keypair: _kp, fp: fp} do
    other_kp = IdentiKey.gen_keypair()
    other_fp = IdentiKey.fingerprint(other_kp)
    :ok = SecretStore.put(other_fp, "identity/pubkey",
      Jason.encode!(%{"pubkey" => Base.encode64(other_kp.ed25519_public)}))

    fqdn = "mismatch.example.com"
    # Record claims other_fp but URL uses fp
    alias_bytes = signed_alias_bytes(other_kp, other_fp, "blog", fqdn)

    conn = call(:put, "/#{fp}/blog/aliases/#{fqdn}", alias_bytes)
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "identikey_mismatch"
  end

  test "PUT alias rejects fqdn mismatch", %{keypair: kp, fp: fp} do
    fqdn_in_record = "record.example.com"
    fqdn_in_url = "url.example.com"
    alias_bytes = signed_alias_bytes(kp, fp, "blog", fqdn_in_record)

    conn = call(:put, "/#{fp}/blog/aliases/#{fqdn_in_url}", alias_bytes)
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "fqdn_mismatch"
  end

  test "PUT alias rejects bad JSON body", %{fp: fp} do
    conn = call(:put, "/#{fp}/blog/aliases/any.example.com", "not json")
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "bad_alias_record"
  end

  test "DELETE /:fp/:name/aliases/:fqdn removes alias and returns 204", %{keypair: kp, fp: fp} do
    fqdn = "delete-me.example.com"
    alias_bytes = signed_alias_bytes(kp, fp, "blog", fqdn, 1)
    assert 201 == call(:put, "/#{fp}/blog/aliases/#{fqdn}", alias_bytes).status

    # Tombstone: higher sequence
    tombstone = signed_alias_bytes(kp, fp, "blog", fqdn, 2)
    conn = call(:delete, "/#{fp}/blog/aliases/#{fqdn}", tombstone)
    assert conn.status == 204

    # Alias lookup should now return not_found
    assert 404 == call(:get, "/aliases/lookup?host=#{fqdn}").status
  end

  ## Alias test helper

  defp signed_alias_bytes(keypair, fp, site_name, fqdn, seq \\ 1) do
    alias Mjolnir.Sites.AliasRecord

    record = %AliasRecord{
      version: 1,
      identikey_fp: fp,
      site_name: site_name,
      fqdn: fqdn,
      sequence: seq,
      created_at: ~U[2026-05-13 12:00:00Z],
      signature: nil
    }

    signing_bytes = AliasRecord.canonical_signing_bytes(record)
    sig = IdentiKey.sign(keypair, signing_bytes)
    AliasRecord.serialize(%{record | signature: sig})
  end
end
