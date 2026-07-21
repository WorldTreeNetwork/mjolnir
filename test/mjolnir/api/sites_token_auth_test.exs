defmodule Mjolnir.API.SitesTokenAuthTest do
  @moduledoc """
  End-to-end coverage for scoped Sites publishing credentials, driven through
  the real `Mjolnir.API.Router` so the `Auth` plug, the forward to
  `SitesRouter`, and the binding check all run exactly as they do in production.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias Mjolnir.API.Router
  alias Mjolnir.SecretStore
  alias Mjolnir.Sites.{Crypto, IdentiKey, Manifest, TokenStore}
  alias Mjolnir.Sites.Manifest.Entry

  @opts Router.init([])

  # Forgejo runner VMs reach the host here, not on loopback — the reason a
  # scoped credential is needed at all.
  @remote_ip {10, 255, 255, 1}

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("mjolnir-sites-token-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([tmp, "blob", "b3"]))
    File.mkdir_p!(Path.join([tmp, "manifests"]))
    keyspace = Path.join(tmp, "keyspace")
    tokens = Path.join(tmp, "tokens")
    File.mkdir_p!(keyspace)
    File.mkdir_p!(tokens)

    orig = %{
      sites: Application.get_env(:mjolnir, :sites_root),
      secret: Application.get_env(:mjolnir, :secret_store_root),
      materialized: Application.get_env(:mjolnir, :sites_materialized_root),
      tokens: Application.get_env(:mjolnir, :sites_token_dir)
    }

    Application.put_env(:mjolnir, :sites_root, tmp)
    Application.put_env(:mjolnir, :secret_store_root, keyspace)
    Application.put_env(:mjolnir, :sites_materialized_root, Path.join(tmp, "materialized"))
    Application.put_env(:mjolnir, :sites_token_dir, tokens)

    keypair = IdentiKey.gen_keypair()
    fp = IdentiKey.fingerprint(keypair)

    :ok =
      SecretStore.put(
        fp,
        "identity/pubkey",
        Jason.encode!(%{"pubkey" => Base.encode64(keypair.ed25519_public)})
      )

    created = TokenStore.list() |> Enum.map(& &1.id) |> MapSet.new()

    on_exit(fn ->
      Enum.each(TokenStore.list(), fn t ->
        unless MapSet.member?(created, t.id), do: TokenStore.delete(t.id)
      end)

      Application.put_env(:mjolnir, :sites_root, orig.sites)
      Application.put_env(:mjolnir, :secret_store_root, orig.secret)
      Application.put_env(:mjolnir, :sites_materialized_root, orig.materialized)
      Application.put_env(:mjolnir, :sites_token_dir, orig.tokens)
      File.rm_rf!(tmp)
    end)

    {:ok, keypair: keypair, fp: fp}
  end

  ## Request helpers

  defp call(method, path, body, opts \\ []) do
    conn = conn(method, path, body)
    conn = %{conn | remote_ip: Keyword.get(opts, :remote_ip, @remote_ip)}

    conn =
      case Keyword.get(opts, :token) do
        nil -> conn
        t -> put_req_header(conn, "authorization", "Bearer " <> t)
      end

    Router.call(conn, @opts)
  end

  defp mint!(fp, opts \\ []) do
    {:ok, _token, plaintext} = TokenStore.create(fp, opts)
    plaintext
  end

  ## Snapshot fixtures

  defp sample_manifest(fp, name, body \\ "<h1>hi</h1>") do
    sym_seed = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(24)
    sym_key = Crypto.hkdf_sha256(sym_seed, "/index.html", 32)
    ciphertext = Crypto.xchacha20_encrypt(sym_key, nonce, body)
    chunk_hash = Crypto.blake3_hash_base58(ciphertext)

    manifest = %Manifest{
      version: 1,
      identikey_fp: fp,
      site_name: name,
      mode: :public,
      created_at: ~U[2026-05-13 12:00:00Z],
      sym_seed: sym_seed,
      signatures: <<1, 2, 3>>,
      entries: [
        %Entry{
          path: "/index.html",
          content_type: "text/html; charset=utf-8",
          bao_hash: chunk_hash,
          ciphertext_size: byte_size(ciphertext),
          plaintext_size: byte_size(body),
          nonce: nonce,
          wrapped_key: nil,
          content_encoding: nil
        }
      ]
    }

    %{bytes: Manifest.serialize(manifest), ciphertext: ciphertext, chunk_hash: chunk_hash}
  end

  defp signed_head_bytes(keypair, manifest_bytes, fp, name, seq) do
    head = %Mjolnir.Sites.HeadRecord{
      version: 1,
      identikey_fp: fp,
      site_name: name,
      snapshot_hash: Manifest.snapshot_hash(manifest_bytes),
      sequence: seq,
      created_at: ~U[2026-05-13 12:00:00Z],
      signature: nil
    }

    sig = IdentiKey.sign(keypair, Mjolnir.Sites.HeadRecord.canonical_signing_bytes(head))
    Mjolnir.Sites.HeadRecord.serialize(%{head | signature: sig})
  end

  defp frame_chunk(ct, ob) do
    <<byte_size(ct)::big-unsigned-64, ct::binary, byte_size(ob)::big-unsigned-64, ob::binary>>
  end

  ## Tests

  describe "scope confinement" do
    test "a sites token cannot reach the VM control plane", %{fp: fp} do
      token = mint!(fp)

      for {method, path} <- [
            {:post, "/api/vms"},
            {:get, "/api/vms"},
            {:get, "/api/snapshots"}
          ] do
        conn = call(method, path, "", token: token)

        assert conn.status == 403,
               "#{method} #{path} returned #{conn.status}, expected 403"

        assert Jason.decode!(conn.resp_body)["error"] == "insufficient_scope"
      end
    end

    test "the token's scope claim is exactly sites:publish", %{fp: fp} do
      token = mint!(fp)
      conn = call(:get, "/api/sites/#{fp}/blog/head", "", token: token)

      assert conn.assigns[:claims]["scope"] == "sites:publish"
      assert conn.assigns[:user_id] =~ ~r/^sites_token:[a-f0-9]{16}$/
    end

    test "presenting a sites token from loopback does not grant full access", %{fp: fp} do
      # Ordering property: the sites-token branch runs before the loopback
      # bypass, so a scoped credential is never silently upgraded.
      token = mint!(fp)
      conn = call(:get, "/api/vms", "", token: token, remote_ip: {127, 0, 0, 1})

      assert conn.status == 403
      assert conn.assigns[:claims]["scope"] == "sites:publish"
    end

    test "the loopback bypass is unchanged for uncredentialed requests" do
      conn = call(:get, "/api/vms", "", remote_ip: {127, 0, 0, 1})

      refute conn.status == 401
      assert conn.assigns[:user_id] == "localhost"
      assert conn.assigns[:claims]["scope"] =~ "vms:read"
    end

    test "a non-loopback request with no credential is still rejected" do
      conn = call(:get, "/api/vms", "")
      assert conn.status == 401
    end
  end

  describe "fingerprint binding" do
    test "a token cannot publish under another fingerprint", %{fp: fp} do
      other = IdentiKey.gen_keypair() |> IdentiKey.fingerprint()
      token = mint!(fp)

      %{bytes: bytes} = sample_manifest(other, "blog")
      conn = call(:post, "/api/sites/#{other}/blog/snapshot", bytes, token: token)

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] == "token_scope_mismatch"
    end

    test "the mismatch is refused before the handler runs", %{fp: fp} do
      other = IdentiKey.gen_keypair() |> IdentiKey.fingerprint()
      token = mint!(fp)

      # A body that would otherwise 400 as a bad manifest still 403s, proving
      # the binding check halts ahead of dispatch.
      conn = call(:post, "/api/sites/#{other}/blog/snapshot", "not a manifest", token: token)
      assert conn.status == 403
    end

    test "identity registration is fingerprint-bound too", %{fp: fp} do
      other = IdentiKey.gen_keypair() |> IdentiKey.fingerprint()
      token = mint!(fp)

      conn = call(:put, "/api/sites/#{other}/identity", "{}", token: token)
      assert conn.status == 403
    end

    test "alias writes are fingerprint-bound too", %{fp: fp} do
      other = IdentiKey.gen_keypair() |> IdentiKey.fingerprint()
      token = mint!(fp)

      assert call(:put, "/api/sites/#{other}/blog/aliases/x.example.com", "", token: token).status ==
               403

      assert call(:delete, "/api/sites/#{other}/blog/aliases/x.example.com", "", token: token).status ==
               403
    end
  end

  describe "site binding" do
    test "a site-bound token cannot publish another site", %{fp: fp} do
      token = mint!(fp, site_name: "blog")

      %{bytes: bytes} = sample_manifest(fp, "secrets")
      conn = call(:post, "/api/sites/#{fp}/secrets/snapshot", bytes, token: token)

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] == "token_scope_mismatch"
    end

    test "an unbound token may publish any site under its fingerprint", %{fp: fp} do
      token = mint!(fp)

      %{bytes: bytes} = sample_manifest(fp, "anything")
      conn = call(:post, "/api/sites/#{fp}/anything/snapshot", bytes, token: token)

      assert conn.status == 201
    end
  end

  describe "revocation and expiry" do
    test "a revoked token is rejected", %{fp: fp} do
      {:ok, token, plaintext} = TokenStore.create(fp)
      assert call(:get, "/api/sites/#{fp}/blog/head", "", token: plaintext).status != 401

      :ok = TokenStore.revoke(token.id)

      conn = call(:get, "/api/sites/#{fp}/blog/head", "", token: plaintext)
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"] == "invalid_token"
    end

    test "an expired token is rejected", %{fp: fp} do
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      plaintext = mint!(fp, expires_at: past)

      assert call(:get, "/api/sites/#{fp}/blog/head", "", token: plaintext).status == 401
    end

    test "a forged secret for a real token id is rejected", %{fp: fp} do
      {:ok, token, _plaintext} = TokenStore.create(fp)

      conn = call(:get, "/api/sites/#{fp}/blog/head", "", token: "mjsk_#{token.id}_forged")
      assert conn.status == 401
    end

    test "the rejection does not reveal why", %{fp: fp} do
      {:ok, token, _} = TokenStore.create(fp)
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      expired = mint!(fp, expires_at: past)

      bodies =
        for cred <- ["mjsk_#{token.id}_forged", expired, "mjsk_ffffffffffffffff_nope"] do
          call(:get, "/api/sites/#{fp}/blog/head", "", token: cred).resp_body
        end

      # Unknown id, bad secret, and expired must be indistinguishable to a caller.
      assert Enum.uniq(bodies) == [~s({"error":"invalid_token"})]
    end
  end

  describe "the full publish flow" do
    test "succeeds end to end with a correctly scoped token", %{keypair: kp, fp: fp} do
      token = mint!(fp, site_name: "blog")
      %{bytes: mbytes, ciphertext: ct, chunk_hash: hash} = sample_manifest(fp, "blog")

      # 1. identity
      identity = Jason.encode!(%{"pubkey" => Base.encode64(kp.ed25519_public)})
      assert call(:put, "/api/sites/#{fp}/identity", identity, token: token).status == 201

      # 2. manifest
      snap = call(:post, "/api/sites/#{fp}/blog/snapshot", mbytes, token: token)
      assert snap.status == 201
      assert Jason.decode!(snap.resp_body)["missing_chunks"] == [hash]

      # 3. chunk
      assert call(:put, "/api/sites/blob/#{hash}", frame_chunk(ct, ""), token: token).status ==
               201

      # 4. head
      head = signed_head_bytes(kp, mbytes, fp, "blog", 1)
      head_conn = call(:post, "/api/sites/#{fp}/blog/head", head, token: token)
      assert head_conn.status == 200
      assert Jason.decode!(head_conn.resp_body)["sequence"] == 1

      # 5. the site serves
      serve = call(:get, "/api/sites/#{fp}/blog/files/index.html", "", token: token)
      assert serve.status == 200
      assert serve.resp_body == "<h1>hi</h1>"
    end

    test "an alias write succeeds for the bound fingerprint", %{keypair: kp, fp: fp} do
      token = mint!(fp)
      alias_bytes = Mjolnir.Sites.Publisher.build_alias(kp, fp, "blog", "x.example.com", 1)

      conn =
        call(:put, "/api/sites/#{fp}/blog/aliases/x.example.com", alias_bytes, token: token)

      assert conn.status == 201
    end
  end

  describe "unbound routes" do
    test "blob upload is reachable with any valid token", %{fp: fp} do
      # Documented decision: /blob/:hash carries no fingerprint and is
      # content-addressed, so it is scoped by token validity, not by fp.
      other = IdentiKey.gen_keypair() |> IdentiKey.fingerprint()
      token = mint!(other)

      ct = "some-ciphertext"
      hash = Crypto.blake3_hash_base58(ct)

      assert call(:put, "/api/sites/blob/#{hash}", frame_chunk(ct, ""), token: token).status ==
               201

      _ = fp
    end

    test "a blob write cannot forge content under an existing hash", %{fp: fp} do
      # The property the blob decision rests on: put_chunk recomputes the hash,
      # so a chunk name can only ever hold the bytes that hash to it.
      token = mint!(fp)
      ct = "honest-bytes"
      hash = Crypto.blake3_hash_base58(ct)

      assert call(:put, "/api/sites/blob/#{hash}", frame_chunk(ct, ""), token: token).status ==
               201

      tampered =
        call(:put, "/api/sites/blob/#{hash}", frame_chunk("evil-bytes", ""), token: token)

      assert tampered.status == 400
      assert Jason.decode!(tampered.resp_body)["error"] =~ "bao_mismatch"

      # Original bytes intact.
      assert call(:get, "/api/sites/blob/#{hash}", "", token: token).resp_body == ct
    end
  end
end
