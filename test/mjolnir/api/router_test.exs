defmodule Mjolnir.API.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Mjolnir.API.Router

  @opts Router.init([])

  setup do
    original = Application.get_env(:mjolnir, :auth, [])
    Application.put_env(:mjolnir, :auth, bypass_localhost: true)
    on_exit(fn -> Application.put_env(:mjolnir, :auth, original) end)
    :ok
  end

  defp request(method, path, body \\ nil) do
    conn = conn(method, path, body && Jason.encode!(body))

    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  describe "GET /api/health" do
    test "returns 200 with status ok" do
      conn = request(:get, "/api/health")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
    end
  end

  describe "GET /api/vms" do
    test "returns 200 with empty VM list" do
      conn = request(:get, "/api/vms")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["vms"] == []
    end
  end

  describe "GET /api/vms/:id" do
    test "returns 404 for non-existent VM" do
      conn = request(:get, "/api/vms/nonexistent-id")
      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_found"
    end
  end

  describe "DELETE /api/vms/:id" do
    test "returns 404 for non-existent VM" do
      conn = request(:delete, "/api/vms/nonexistent-id")
      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_found"
    end
  end

  describe "GET /api/vms/:id/ticket" do
    test "returns 404 for non-existent VM" do
      conn = request(:get, "/api/vms/nonexistent-id/ticket")
      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_found"
    end
  end

  describe "GET /api/vms/:id/node-id" do
    test "returns 404 for non-existent VM" do
      conn = request(:get, "/api/vms/nonexistent-id/node-id")
      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_found"
    end
  end

  describe "POST /api/vms/:id/reboot" do
    test "returns 404 for non-existent VM" do
      conn = request(:post, "/api/vms/nonexistent-id/reboot")
      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_found"
    end
  end

  describe "unknown routes" do
    test "returns 404" do
      conn = request(:get, "/api/unknown")
      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_found"
    end
  end

  describe "GET /api/dormant" do
    test "returns empty list when no dormant VMs" do
      conn = request(:get, "/api/dormant")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["dormant"] == []
    end

    test "returns dormant VMs with correct shape" do
      vm_id = "test-dormant-#{:erlang.unique_integer([:positive])}"
      Mjolnir.DormantRegistry.register(vm_id, "snap-1", %{vcpus: 1})

      on_exit(fn -> Mjolnir.DormantRegistry.unregister(vm_id) end)

      conn = request(:get, "/api/dormant")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert [entry] = body["dormant"]
      assert entry["vm_id"] == vm_id
      assert entry["snapshot_name"] == "snap-1"
      assert entry["pending_messages"] == 0
      assert entry["state"] == "dormant"
      assert is_binary(entry["dormant_since"])
    end
  end

  describe "scope enforcement" do
    setup do
      Application.put_env(:mjolnir, :auth, bypass_localhost: false)
      :ok
    end

    test "returns 401 without token from non-localhost" do
      conn =
        conn(:get, "/api/vms")
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 401
    end
  end

  describe "VanityHostPlug — custom-domain site serving" do
    alias Mjolnir.SecretStore
    alias Mjolnir.Sites.{AliasRecord, Crypto, IdentiKey, Manifest, Store}
    alias Mjolnir.Sites.Manifest.Entry

    setup do
      tmp =
        System.tmp_dir!()
        |> Path.join("mjolnir-vanity-router-test-#{System.unique_integer([:positive])}")

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

    defp publish_site(keypair, fp, site_name) do
      sym_seed = :crypto.strong_rand_bytes(32)
      nonce = :crypto.strong_rand_bytes(24)
      plaintext = "<h1>vanity</h1>"
      path = "/index.html"
      sym_key = Crypto.hkdf_sha256(sym_seed, path, 32)
      ciphertext = Crypto.xchacha20_encrypt(sym_key, nonce, plaintext)
      chunk_hash = Crypto.blake3_hash_base58(ciphertext)

      manifest = %Manifest{
        version: 1,
        identikey_fp: fp,
        site_name: site_name,
        mode: :public,
        created_at: DateTime.utc_now() |> DateTime.truncate(:second),
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

      # Sign and store HEAD
      alias Mjolnir.Sites.HeadRecord

      head = %HeadRecord{
        version: 1,
        identikey_fp: fp,
        site_name: site_name,
        snapshot_hash: hash,
        sequence: 1,
        created_at: DateTime.utc_now() |> DateTime.truncate(:second),
        signature: nil
      }

      sig = IdentiKey.sign(keypair, HeadRecord.canonical_signing_bytes(head))
      head_bytes = HeadRecord.serialize(%{head | signature: sig})
      :ok = SecretStore.put(fp, "sites/#{site_name}/HEAD", head_bytes)

      {plaintext, chunk_hash}
    end

    defp publish_alias(keypair, fp, site_name, fqdn) do
      record = %AliasRecord{
        version: 1,
        identikey_fp: fp,
        site_name: site_name,
        fqdn: fqdn,
        sequence: 1,
        created_at: DateTime.utc_now() |> DateTime.truncate(:second),
        signature: nil
      }

      sig = IdentiKey.sign(keypair, AliasRecord.canonical_signing_bytes(record))
      alias_bytes = AliasRecord.serialize(%{record | signature: sig})
      :ok = SecretStore.put(fp, "sites/#{site_name}/aliases/#{fqdn}", alias_bytes)
    end

    test "vanity host request serves site content", %{keypair: kp, fp: fp} do
      {plaintext, _} = publish_site(kp, fp, "blog")
      :ok = publish_alias(kp, fp, "blog", "blog.duke.io")

      conn =
        conn(:get, "/index.html")
        |> Map.put(:host, "blog.duke.io")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Router.call(@opts)

      assert conn.status == 200
      assert conn.resp_body == plaintext
      assert conn.halted
    end

    test "localhost host is not treated as vanity", _ctx do
      conn =
        conn(:get, "/some-path")
        |> Map.put(:host, "localhost")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Router.call(@opts)

      # Falls through to normal router — 404 not_found
      assert conn.status == 404
    end

    test "path starting with /api/ skips vanity plug even for custom host", %{keypair: kp, fp: fp} do
      :ok = publish_alias(kp, fp, "blog", "blog.duke.io")

      conn =
        conn(:get, "/api/health")
        |> Map.put(:host, "blog.duke.io")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Router.call(@opts)

      # Should reach the health endpoint normally
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["status"] == "ok"
    end

    test "unknown vanity host falls through to 404", _ctx do
      conn =
        conn(:get, "/index.html")
        |> Map.put(:host, "unknown.vanity.io")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Router.call(@opts)

      assert conn.status == 404
    end
  end
end
