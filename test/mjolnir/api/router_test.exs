defmodule Mjolnir.API.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Mjolnir.API.Router

  @opts Router.init([])

  setup do
    original = Application.get_env(:mjolnir, :auth, [])
    Application.put_env(:mjolnir, :auth, bypass_localhost: true)

    orig_src = Application.get_env(:mjolnir, :deploy_src_dir)
    src_dir = Path.join(System.tmp_dir!(), "deploy-src-#{System.unique_integer([:positive])}")
    Application.put_env(:mjolnir, :deploy_src_dir, src_dir)

    on_exit(fn ->
      Application.put_env(:mjolnir, :auth, original)
      if orig_src, do: Application.put_env(:mjolnir, :deploy_src_dir, orig_src)
      File.rm_rf(src_dir)
    end)

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
    test "returns 200 with a vms list" do
      conn = request(:get, "/api/vms")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      # Deliberately a shape assertion, not `== []`. No VM is spawned here, so
      # emptiness was only ever asserting that nothing else in the run (or, as
      # it turned out, in any PREVIOUS run — mjolnir-7qh) had written to the
      # process-global StateStore. That is not this endpoint's contract.
      assert is_list(body["vms"])
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

  describe "GET /api/apps" do
    test "returns 200 with an apps list" do
      conn = request(:get, "/api/apps")
      assert conn.status == 200
      assert is_list(Jason.decode!(conn.resp_body)["apps"])
    end
  end

  describe "PUT/DELETE /api/apps/:app/domain" do
    test "404 setting a domain on an unknown app" do
      conn =
        request(:put, "/api/apps/nope-#{System.unique_integer([:positive])}/domain", %{
          fqdn: "x.identikey.io"
        })

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"] == "app_not_found"
    end

    test "400 when fqdn is missing" do
      # The app must exist: since mjolnir-xuv, ownership is resolved BEFORE the
      # body is validated, so an unknown app is a 404 regardless of the body —
      # a caller should not learn their payload was malformed for a resource
      # they cannot see.
      app = "domtest-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Mjolnir.Deploy.Registry.put(app, %{
          release_snapshot: "deploy-x",
          service_vm_id: "svc-x",
          url: "https://x",
          port: 3000
        })

      on_exit(fn -> Mjolnir.Deploy.Registry.delete(app) end)

      conn = request(:put, "/api/apps/#{app}/domain", %{})
      assert conn.status == 400
    end

    test "404, not 400, when the app is unknown and the body is also invalid" do
      conn = request(:put, "/api/apps/whatever-#{System.unique_integer()}/domain", %{})
      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"] == "app_not_found"
    end

    test "404 removing a domain from an unknown app" do
      conn = request(:delete, "/api/apps/nope-#{System.unique_integer([:positive])}/domain")
      assert conn.status == 404
    end

    test "400 apex_not_registered for a seeded app with an unconfigured apex" do
      app = "domtest-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Mjolnir.Deploy.Registry.put(app, %{
          release_snapshot: "deploy-x",
          service_vm_id: "svc-x",
          url: "https://x",
          port: 3000
        })

      on_exit(fn -> Mjolnir.Deploy.Registry.delete(app) end)

      conn = request(:put, "/api/apps/#{app}/domain", %{fqdn: "x.example.com"})
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "apex_not_registered"
    end
  end

  describe "POST /api/certs/issue" do
    test "400 when fqdn is missing" do
      conn = request(:post, "/api/certs/issue", %{})
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "fqdn is required"
    end

    test "400 refuses wildcards and never issues" do
      conn = request(:post, "/api/certs/issue", %{fqdn: "*.taskmaster.dev"})
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "wildcard_not_supported"
    end

    test "404 when no app owns the domain" do
      conn = request(:post, "/api/certs/issue", %{fqdn: "no-such-#{System.unique_integer()}.dev"})
      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"] == "app_not_found"
    end
  end

  describe "GET /api/certs" do
    test "returns 200 with a certs list (no PEMs)" do
      conn = request(:get, "/api/certs")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["certs"])

      for c <- body["certs"] do
        refute Map.has_key?(c, "cert")
        refute Map.has_key?(c, "key")
        refute Map.has_key?(c, "fullchain")
        refute Map.has_key?(c, "privkey")
      end
    end
  end

  describe "POST /api/deploy" do
    test "400 for a body that is not a gzipped tar" do
      conn =
        conn(:post, "/api/deploy", "this is not a tarball")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("x-app-name", "junk-app")
        |> Router.call(@opts)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "invalid_source_archive"
    end

    test "streams NDJSON and reports a detect failure for an unsupported app" do
      # A valid gzipped tar whose contents are not a recognised app (no
      # package.json / svelte.config.js) → detection fails. Exercises the full
      # streaming path with no VM/KVM needed.
      dir = Path.join(System.tmp_dir!(), "deploytar-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "myapp"))
      File.write!(Path.join([dir, "myapp", "README.md"]), "# hi")
      tar = Path.join(dir, "src.tgz")

      :ok =
        :erl_tar.create(
          String.to_charlist(tar),
          [{~c"myapp", String.to_charlist(Path.join(dir, "myapp"))}],
          [:compressed]
        )

      body = File.read!(tar)
      on_exit(fn -> File.rm_rf(dir) end)

      conn =
        conn(:post, "/api/deploy", body)
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("x-app-name", "myapp")
        |> Router.call(@opts)

      assert conn.status == 200

      lines =
        conn.resp_body
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      final = List.last(lines)
      assert final["ok"] == false
      assert final["stage"] == "detect"
    end
  end

  describe "metadata validation" do
    alias Mjolnir.API.Validation

    test "accepts a plain string map and coerces non-string values" do
      assert {:ok, %{"buzz.managed-by" => "buzz-backend-mjolnir"}} =
               Validation.validate_metadata(%{"buzz.managed-by" => "buzz-backend-mjolnir"})

      assert {:ok, %{"n" => "42"}} = Validation.validate_metadata(%{"n" => 42})
    end

    test "rejects a non-object" do
      assert {:error, _} = Validation.validate_metadata("nope")
      assert {:error, _} = Validation.validate_metadata([1, 2])
    end

    test "rejects empty keys" do
      assert {:error, msg} = Validation.validate_metadata(%{"" => "v"})
      assert msg =~ "empty"
    end

    test "bounds the number of keys" do
      too_many = Map.new(1..33, fn i -> {"k#{i}", "v"} end)
      assert {:error, msg} = Validation.validate_metadata(too_many)
      assert msg =~ "too many keys"
    end

    test "bounds key and value length" do
      assert {:error, msg} = Validation.validate_metadata(%{String.duplicate("k", 129) => "v"})
      assert msg =~ "key too long"

      assert {:error, msg} = Validation.validate_metadata(%{"k" => String.duplicate("v", 513)})
      assert msg =~ "too long"
    end

    test "refuses control characters in keys and values" do
      # Metadata is echoed into JSON and written to a file; a newline has no
      # business in either.
      assert {:error, msg} = Validation.validate_metadata(%{"k" => "a\nb"})
      assert msg =~ "control characters"

      assert {:error, _} = Validation.validate_metadata(%{"a\tb" => "v"})
      assert {:error, _} = Validation.validate_metadata(%{"k" => "a\u0000b"})
    end

    test "allows the punctuation an orchestrator actually uses in label keys" do
      assert {:ok, _} =
               Validation.validate_metadata(%{
                 "app.kubernetes.io/managed-by" => "x",
                 "buzz.agent-pubkey" => String.duplicate("a", 64)
               })
    end
  end

  describe "GET /api/vms metadata filtering" do
    alias Mjolnir.StateStore
    alias Mjolnir.StateStore.Record

    setup do
      tmp =
        Path.join([
          System.tmp_dir!(),
          "mjolnir-router-meta",
          "#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(Path.join(tmp, "quarantine"))
      prev = Application.get_env(:mjolnir, :state_dir)
      Application.put_env(:mjolnir, :state_dir, tmp)
      :ok = StateStore.reload()

      on_exit(fn ->
        File.rm_rf!(tmp)
        if prev, do: Application.put_env(:mjolnir, :state_dir, prev)
        :ok = StateStore.reload()
      end)

      # Records with :running intent and no live GenServer surface as stranded,
      # which is enough to exercise the filter without booting a hypervisor.
      :ok =
        StateStore.put(
          Record.new("meta-a", :running, metadata: %{"app" => "buzz", "id" => "aaa"})
        )

      :ok =
        StateStore.put(
          Record.new("meta-b", :running, metadata: %{"app" => "buzz", "id" => "bbb"})
        )

      :ok = StateStore.put(Record.new("meta-c", :running, metadata: %{"app" => "other"}))

      :ok
    end

    defp vm_ids(conn) do
      conn.resp_body
      |> Jason.decode!()
      |> Map.fetch!("vms")
      |> Enum.map(& &1["id"])
      |> Enum.sort()
    end

    test "no selector returns everything" do
      conn = request(:get, "/api/vms")
      assert conn.status == 200
      assert vm_ids(conn) == ["meta-a", "meta-b", "meta-c"]
    end

    test "a single pair narrows the list" do
      conn = request(:get, "/api/vms?metadata.app=buzz")
      assert vm_ids(conn) == ["meta-a", "meta-b"]
    end

    test "every pair must match" do
      conn = request(:get, "/api/vms?metadata.app=buzz&metadata.id=bbb")
      assert vm_ids(conn) == ["meta-b"]
    end

    test "a non-matching value returns nothing rather than everything" do
      conn = request(:get, "/api/vms?metadata.app=nosuch")
      assert vm_ids(conn) == []
    end

    test "an unknown key matches nothing" do
      conn = request(:get, "/api/vms?metadata.nokey=x")
      assert vm_ids(conn) == []
    end

    test "metadata and generation are exposed on each row" do
      conn = request(:get, "/api/vms?metadata.id=aaa")
      [row] = conn.resp_body |> Jason.decode!() |> Map.fetch!("vms")

      assert row["metadata"] == %{"app" => "buzz", "id" => "aaa"}
      assert row["generation"] == 1
    end

    test "a non-metadata query param is not treated as a selector" do
      conn = request(:get, "/api/vms?dormant=true")
      assert vm_ids(conn) == ["meta-a", "meta-b", "meta-c"]
    end
  end
end
