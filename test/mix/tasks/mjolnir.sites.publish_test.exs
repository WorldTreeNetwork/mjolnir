defmodule Mix.Tasks.Mjolnir.Sites.PublishTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Mjolnir.API.SitesRouter
  alias Mjolnir.SecretStore
  alias Mjolnir.Sites.{Crypto, HeadRecord, IdentiKey, Manifest, Publisher}

  @opts SitesRouter.init([])

  # ---------------------------------------------------------------------------
  # Setup: temp dirs for store + secret store, mirroring sites_router_test.exs
  # ---------------------------------------------------------------------------

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("mjolnir-publish-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([tmp, "blob", "b3"]))
    File.mkdir_p!(Path.join([tmp, "manifests"]))
    keyspace = Path.join(tmp, "keyspace")
    File.mkdir_p!(keyspace)

    orig_sites = Application.get_env(:mjolnir, :sites_root)
    orig_secret = Application.get_env(:mjolnir, :secret_store_root)
    Application.put_env(:mjolnir, :sites_root, tmp)
    Application.put_env(:mjolnir, :secret_store_root, keyspace)

    # Build a temp source directory with a few files
    src = Path.join(tmp, "src")
    File.mkdir_p!(Path.join(src, "about"))
    File.write!(Path.join(src, "index.html"), "<html>home</html>")
    File.write!(Path.join(src, "about/index.html"), "<html>about</html>")
    File.write!(Path.join(src, "style.css"), "body { margin: 0; }")

    # Generate a keypair and register its identity so SecretStore accepts HEAD records
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

    {:ok, tmp: tmp, src: src, keypair: keypair, fp: fp}
  end

  # Shared helper: call the router in-process (no network needed)
  defp call(method, path, body \\ "") do
    conn(method, path, body) |> SitesRouter.call(@opts)
  end

  defp signed_head_bytes(keypair, fp, site, snapshot_hash, seq) do
    head = %HeadRecord{
      version: 1,
      identikey_fp: fp,
      site_name: site,
      snapshot_hash: snapshot_hash,
      sequence: seq,
      created_at: DateTime.utc_now() |> DateTime.truncate(:second),
      signature: nil
    }

    signing_bytes = HeadRecord.canonical_signing_bytes(head)
    sig = IdentiKey.sign(keypair, signing_bytes)
    %{head | signature: sig} |> HeadRecord.serialize()
  end

  # ---------------------------------------------------------------------------
  # Unit tests for Publisher.build_snapshot/4
  # ---------------------------------------------------------------------------

  describe "build_snapshot/4" do
    test "returns a manifest with one entry per file", %{src: src, fp: fp} do
      {manifest, chunks} = Publisher.build_snapshot(src, fp, "mysite")

      assert manifest.identikey_fp == fp
      assert manifest.site_name == "mysite"
      assert manifest.mode == :public
      assert is_binary(manifest.sym_seed) and byte_size(manifest.sym_seed) == 32
      assert length(manifest.entries) == 3

      paths = Enum.map(manifest.entries, & &1.path) |> Enum.sort()
      assert paths == ["/about/index.html", "/index.html", "/style.css"]

      # Every entry has a bao_hash present in the chunk map
      for entry <- manifest.entries do
        assert Map.has_key?(chunks, entry.bao_hash)
        assert entry.nonce != nil and byte_size(entry.nonce) == 24
        assert entry.ciphertext_size > 0
        assert entry.plaintext_size > 0
      end
    end

    test "assigns correct MIME types", %{src: src, fp: fp} do
      {manifest, _chunks} = Publisher.build_snapshot(src, fp, "mysite")

      by_path = Map.new(manifest.entries, &{&1.path, &1.content_type})
      assert by_path["/index.html"] == "text/html; charset=utf-8"
      assert by_path["/about/index.html"] == "text/html; charset=utf-8"
      assert by_path["/style.css"] == "text/css; charset=utf-8"
    end

    test "ciphertext hash matches stored bao_hash", %{src: src, fp: fp} do
      {manifest, chunks} = Publisher.build_snapshot(src, fp, "mysite")

      for entry <- manifest.entries do
        %{ciphertext: ct} = Map.fetch!(chunks, entry.bao_hash)
        assert Crypto.blake3_hash_base58(ct) == entry.bao_hash
      end
    end

    test "accepts an explicit sym_seed via opts", %{src: src, fp: fp} do
      seed = :crypto.strong_rand_bytes(32)
      {manifest, _chunks} = Publisher.build_snapshot(src, fp, "mysite", sym_seed: seed)
      assert manifest.sym_seed == seed
    end

    test "manifest can be serialized and round-tripped", %{src: src, fp: fp} do
      {manifest, _chunks} = Publisher.build_snapshot(src, fp, "mysite")
      bytes = Manifest.serialize(manifest)
      assert {:ok, parsed} = Manifest.parse(bytes)
      assert parsed.site_name == manifest.site_name
      assert length(parsed.entries) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # mime_of/1 unit tests
  # ---------------------------------------------------------------------------

  describe "mime_of/1" do
    test "covers all documented extensions" do
      assert Publisher.mime_of("a.html") == "text/html; charset=utf-8"
      assert Publisher.mime_of("a.css") == "text/css; charset=utf-8"
      assert Publisher.mime_of("a.js") == "application/javascript"
      assert Publisher.mime_of("a.json") == "application/json"
      assert Publisher.mime_of("a.svg") == "image/svg+xml"
      assert Publisher.mime_of("a.png") == "image/png"
      assert Publisher.mime_of("a.jpg") == "image/jpeg"
      assert Publisher.mime_of("a.jpeg") == "image/jpeg"
      assert Publisher.mime_of("a.txt") == "text/plain; charset=utf-8"
      assert Publisher.mime_of("a.bin") == "application/octet-stream"
      assert Publisher.mime_of("no_extension") == "application/octet-stream"
    end
  end

  # ---------------------------------------------------------------------------
  # End-to-end: build_snapshot + manual HTTP calls via Plug.Test
  # ---------------------------------------------------------------------------

  describe "end-to-end via Plug.Test" do
    test "publish then serve round-trips plaintext", %{src: src, keypair: kp, fp: fp} do
      site = "mysite"

      # Use a fixed sym_seed so the test is deterministic
      seed = :crypto.strong_rand_bytes(32)
      {manifest, chunks} = Publisher.build_snapshot(src, fp, site, sym_seed: seed)
      manifest_bytes = Manifest.serialize(manifest)

      # POST snapshot
      conn = call(:post, "/#{fp}/#{site}/snapshot", manifest_bytes)
      assert conn.status == 201

      %{"snapshot_hash" => snapshot_hash, "missing_chunks" => missing} =
        Jason.decode!(conn.resp_body)

      assert is_binary(snapshot_hash)
      assert length(missing) == 3

      # Upload all missing chunks
      for bao_hash <- missing do
        %{ciphertext: ct, outboard: ob} = Map.fetch!(chunks, bao_hash)

        framed =
          <<byte_size(ct)::big-unsigned-64, ct::binary, byte_size(ob)::big-unsigned-64,
            ob::binary>>

        conn = call(:put, "/blob/#{bao_hash}", framed)
        assert conn.status == 201, "chunk upload failed for #{bao_hash}: #{conn.resp_body}"
      end

      # POST HEAD — sign with real keypair
      head_bytes = signed_head_bytes(kp, fp, site, snapshot_hash, 1)
      conn = call(:post, "/#{fp}/#{site}/head", head_bytes)
      assert conn.status == 200

      # Serve each file via the debug endpoint and verify plaintext round-trips
      for serve_path <- ["/index.html", "/about/index.html", "/style.css"] do
        serve_url = "/#{fp}/#{site}/files#{serve_path}"
        conn = call(:get, serve_url)

        assert conn.status == 200,
               "expected 200 for #{serve_url}, got #{conn.status}: #{conn.resp_body}"

        expected =
          case serve_path do
            "/index.html" -> "<html>home</html>"
            "/about/index.html" -> "<html>about</html>"
            "/style.css" -> "body { margin: 0; }"
          end

        assert conn.resp_body == expected,
               "body mismatch for #{serve_path}: got #{inspect(conn.resp_body)}"
      end
    end

    test "second publish with higher sequence succeeds", %{src: src, keypair: kp, fp: fp} do
      site = "seq-test"

      for seq <- [1, 2] do
        {manifest, chunks} = Publisher.build_snapshot(src, fp, site)
        manifest_bytes = Manifest.serialize(manifest)

        conn = call(:post, "/#{fp}/#{site}/snapshot", manifest_bytes)
        assert conn.status == 201

        %{"snapshot_hash" => snapshot_hash, "missing_chunks" => missing} =
          Jason.decode!(conn.resp_body)

        for bao_hash <- missing do
          %{ciphertext: ct, outboard: ob} = Map.fetch!(chunks, bao_hash)

          framed =
            <<byte_size(ct)::big-unsigned-64, ct::binary, byte_size(ob)::big-unsigned-64,
              ob::binary>>

          assert 201 == call(:put, "/blob/#{bao_hash}", framed).status
        end

        head_bytes = signed_head_bytes(kp, fp, site, snapshot_hash, seq)
        conn = call(:post, "/#{fp}/#{site}/head", head_bytes)
        assert conn.status == 200
        assert Jason.decode!(conn.resp_body)["sequence"] == seq
      end
    end
  end
end
