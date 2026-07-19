defmodule Mjolnir.Gateway.CertsTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Gateway.Certs

  # ==========================================================================
  # In-memory fake filesystem + effect recorder.
  #
  # An Agent holds %{files: %{path => content}, chmod: [...], chown: [...],
  # reloads: n, removed: [...]}. Effects read/write this map so tests can assert
  # the full choreography and exercise idempotency (a second ensure sees the
  # files/toml the first wrote). Nothing ever touches the real /etc.
  # ==========================================================================

  defmodule Fake do
    def start(files \\ %{}) do
      {:ok, pid} =
        Agent.start_link(fn ->
          %{files: files, chmod: [], chown: [], mkdir: [], reloads: 0, removed: []}
        end)

      pid
    end

    def opts(pid, extra \\ []) do
      base = [
        gateway_toml_path: "/etc/mjolnir/gateway.toml",
        certs_dir: "/etc/mjolnir/certs",
        read_file: fn path ->
          case Agent.get(pid, & &1.files[path]) do
            nil -> {:error, :enoent}
            content -> {:ok, content}
          end
        end,
        write_file: fn path, content ->
          Agent.update(pid, &put_in(&1, [:files, path], content))
          :ok
        end,
        mkdir_p: fn path ->
          Agent.update(pid, &Map.update!(&1, :mkdir, fn m -> [path | m] end))
          :ok
        end,
        chmod: fn path, mode ->
          Agent.update(pid, &Map.update!(&1, :chmod, fn c -> [{path, mode} | c] end))
          :ok
        end,
        chown: fn path, uid, gid ->
          Agent.update(pid, &Map.update!(&1, :chown, fn c -> [{path, uid, gid} | c] end))
          :ok
        end,
        rm_rf: fn path ->
          Agent.update(pid, fn s ->
            s
            |> Map.update!(:removed, fn r -> [path | r] end)
            |> Map.update!(:files, fn files ->
              for {k, v} <- files, not String.starts_with?(k, path), into: %{}, do: {k, v}
            end)
          end)

          :ok
        end,
        reload: fn ->
          Agent.update(pid, &Map.update!(&1, :reloads, fn n -> n + 1 end))
          :ok
        end,
        # Cert-inspection seam: default to "valid & covers", overridable.
        validate_pair: fn _cert, _key -> :ok end,
        cert_covers: fn _cert, _fqdn -> :ok end,
        cert_info: fn _pem ->
          {:ok, %{not_after: "Jan 1 00:00:00 2030 GMT", issuer: "Test CA", sans: ["example.com"]}}
        end
      ]

      Keyword.merge(base, extra)
    end

    def files(pid), do: Agent.get(pid, & &1.files)
    def file(pid, path), do: Agent.get(pid, & &1.files[path])
    def toml(pid), do: file(pid, "/etc/mjolnir/gateway.toml")
    def chmod(pid), do: Agent.get(pid, & &1.chmod)
    def chown(pid), do: Agent.get(pid, & &1.chown)
    def reloads(pid), do: Agent.get(pid, & &1.reloads)
    def removed(pid), do: Agent.get(pid, & &1.removed)
  end

  @cert_pem "-----BEGIN CERTIFICATE-----\nFAKECERT\n-----END CERTIFICATE-----\n"
  @key_pem "-----BEGIN PRIVATE KEY-----\nFAKEKEY\n-----END PRIVATE KEY-----\n"

  @base_toml """
  listen = "0.0.0.0:80"
  listen_tls = "0.0.0.0:443"

  [[domain]]
  suffix = "identikey.io"

  [[route]]
  apex = "identikey.io"
  subdomain = "zine"
  backend = "10.0.0.1:3000"
  """

  defp with_toml(pid, content),
    do: Agent.update(pid, &put_in(&1, [:files, "/etc/mjolnir/gateway.toml"], content))

  # ==========================================================================
  # slugify / apex_of / render helpers (pure)
  # ==========================================================================

  describe "slugify/1" do
    test "ordinary apex domains map to themselves (downcased)" do
      assert Certs.slugify("StartupCentral.Build") == "startupcentral.build"
      assert Certs.slugify("zine.identikey.io") == "zine.identikey.io"
    end

    test "wildcard prefix becomes wildcard." do
      assert Certs.slugify("*.example.com") == "wildcard.example.com"
    end

    test "unsafe chars are collapsed to a hyphen" do
      assert Certs.slugify("a/b:c example.com") == "a-b-c-example.com"
    end
  end

  describe "apex_of/2" do
    test "defaults to the last two labels" do
      assert Certs.apex_of("www.startupcentral.build") == "startupcentral.build"
      assert Certs.apex_of("startupcentral.build") == "startupcentral.build"
    end

    test "honours an explicit :apex override" do
      assert Certs.apex_of("a.b.co.uk", apex: "b.co.uk") == "b.co.uk"
    end
  end

  describe "render_cert_block/3 and render_domain_block/1" do
    test "emit the exact gateway TOML shape" do
      assert Certs.render_cert_block(
               "startupcentral.build",
               "/etc/mjolnir/certs/startupcentral.build/fullchain.pem",
               "/etc/mjolnir/certs/startupcentral.build/privkey.pem"
             ) ==
               ~s([[cert]]\n) <>
                 ~s(host = "startupcentral.build"\n) <>
                 ~s(cert = "/etc/mjolnir/certs/startupcentral.build/fullchain.pem"\n) <>
                 ~s(key = "/etc/mjolnir/certs/startupcentral.build/privkey.pem")

      assert Certs.render_domain_block("startupcentral.build") ==
               ~s([[domain]]\nsuffix = "startupcentral.build")
    end
  end

  # ==========================================================================
  # ensure/2 :origin_ca
  # ==========================================================================

  describe "ensure/2 :origin_ca — fresh install" do
    setup do
      pid = Fake.start()
      with_toml(pid, @base_toml)
      {:ok, pid: pid}
    end

    test "writes cert/key to the slug dir with correct owner + modes", %{pid: pid} do
      assert {:ok, :installed} =
               Certs.ensure("startupcentral.build",
                 [mode: :origin_ca, cert: @cert_pem, key: @key_pem] ++ Fake.opts(pid)
               )

      cert_path = "/etc/mjolnir/certs/startupcentral.build/fullchain.pem"
      key_path = "/etc/mjolnir/certs/startupcentral.build/privkey.pem"

      assert Fake.file(pid, cert_path) == @cert_pem
      assert Fake.file(pid, key_path) == @key_pem

      # key is 0600, cert 0644, owned by 999:988
      assert {key_path, 0o600} in Fake.chmod(pid)
      assert {cert_path, 0o644} in Fake.chmod(pid)
      assert {key_path, 999, 988} in Fake.chown(pid)
      assert {cert_path, 999, 988} in Fake.chown(pid)
    end

    test "appends a [[cert]] block and reloads", %{pid: pid} do
      assert {:ok, :installed} =
               Certs.ensure("startupcentral.build",
                 [mode: :origin_ca, cert: @cert_pem, key: @key_pem] ++ Fake.opts(pid)
               )

      toml = Fake.toml(pid)
      assert toml =~ ~s([[cert]])
      assert toml =~ ~s(host = "startupcentral.build")
      assert toml =~ ~s(cert = "/etc/mjolnir/certs/startupcentral.build/fullchain.pem")
      assert toml =~ ~s(key = "/etc/mjolnir/certs/startupcentral.build/privkey.pem")
      # original content preserved
      assert toml =~ ~s(suffix = "identikey.io")
      assert Fake.reloads(pid) == 1
    end

    test "adds a [[domain]] block for a new apex", %{pid: pid} do
      Certs.ensure("startupcentral.build",
        [mode: :origin_ca, cert: @cert_pem, key: @key_pem] ++ Fake.opts(pid)
      )

      assert Fake.toml(pid) =~ ~s([[domain]]\nsuffix = "startupcentral.build")
    end

    test "does NOT duplicate a [[domain]] that already exists for the apex", %{pid: pid} do
      # apex identikey.io already has a [[domain]] block in @base_toml
      Certs.ensure("zine2.identikey.io",
        [mode: :origin_ca, cert: @cert_pem, key: @key_pem, apex: "identikey.io"] ++ Fake.opts(pid)
      )

      toml = Fake.toml(pid)
      # exactly one [[domain]] block for identikey.io
      assert length(Regex.scan(~r/suffix = "identikey\.io"/, toml)) == 1
      assert toml =~ ~s(host = "zine2.identikey.io")
    end
  end

  describe "ensure/2 :origin_ca — idempotency" do
    test "a second identical ensure is a no-op ({:ok, :unchanged}, no extra reload)" do
      pid = Fake.start()
      with_toml(pid, @base_toml)
      opts = [mode: :origin_ca, cert: @cert_pem, key: @key_pem] ++ Fake.opts(pid)

      assert {:ok, :installed} = Certs.ensure("startupcentral.build", opts)
      assert Fake.reloads(pid) == 1

      assert {:ok, :unchanged} = Certs.ensure("startupcentral.build", opts)
      # no second write/reload
      assert Fake.reloads(pid) == 1
    end
  end

  describe "ensure/2 :origin_ca — validation" do
    test "rejects a mismatched cert/key pair and writes nothing" do
      pid = Fake.start()
      with_toml(pid, @base_toml)

      opts =
        [mode: :origin_ca, cert: @cert_pem, key: @key_pem] ++
          Fake.opts(pid, validate_pair: fn _c, _k -> {:error, :key_pair_mismatch} end)

      assert {:error, :key_pair_mismatch} = Certs.ensure("startupcentral.build", opts)
      assert Fake.toml(pid) == @base_toml
      assert Fake.reloads(pid) == 0
    end

    test "rejects a cert that does not cover the fqdn" do
      pid = Fake.start()
      with_toml(pid, @base_toml)

      opts =
        [mode: :origin_ca, cert: @cert_pem, key: @key_pem] ++
          Fake.opts(pid, cert_covers: fn _c, fqdn -> {:error, {:san_not_covered, fqdn, []}} end)

      assert {:error, {:san_not_covered, "startupcentral.build", []}} =
               Certs.ensure("startupcentral.build", opts)

      assert Fake.reloads(pid) == 0
    end

    test "requires cert and key PEM" do
      pid = Fake.start()
      with_toml(pid, @base_toml)

      assert {:error, {:missing_pem, :cert}} =
               Certs.ensure("startupcentral.build", [mode: :origin_ca] ++ Fake.opts(pid))

      assert {:error, {:missing_pem, :key}} =
               Certs.ensure(
                 "startupcentral.build",
                 [mode: :origin_ca, cert: @cert_pem] ++ Fake.opts(pid)
               )
    end
  end

  # ==========================================================================
  # ensure/2 :acme
  # ==========================================================================

  describe "ensure/2 :acme" do
    @acme_toml """
    listen_tls = "0.0.0.0:443"

    [acme]
    enabled = true
    email = "ops@worldtree.io"
    domains = ["vm.worldtree.network"]
    """

    test "rejects a non-worldtree zone explicitly" do
      pid = Fake.start()
      with_toml(pid, @acme_toml)

      assert {:error, {:acme_unsupported_zone, "startupcentral.build"}} =
               Certs.ensure("startupcentral.build", [mode: :acme] ++ Fake.opts(pid))

      assert Fake.reloads(pid) == 0
    end

    test "adds a worldtree fqdn to [acme].domains and reloads" do
      pid = Fake.start()
      with_toml(pid, @acme_toml)

      assert {:ok, :acme_requested} =
               Certs.ensure("app.worldtree.network", [mode: :acme] ++ Fake.opts(pid))

      toml = Fake.toml(pid)
      assert toml =~ ~s(domains = ["vm.worldtree.network", "app.worldtree.network"])
      assert Fake.reloads(pid) == 1
    end

    test "is a no-op when the fqdn is already in [acme].domains" do
      pid = Fake.start()
      with_toml(pid, @acme_toml)

      assert {:ok, :unchanged} =
               Certs.ensure("vm.worldtree.network", [mode: :acme] ++ Fake.opts(pid))

      assert Fake.reloads(pid) == 0
    end
  end

  # ==========================================================================
  # list/0
  # ==========================================================================

  describe "list/1" do
    test "enumerates [[cert]] blocks with details from cert_info" do
      toml = """
      [[cert]]
      host = "startupcentral.build"
      cert = "/etc/mjolnir/certs/startupcentral.build/fullchain.pem"
      key = "/etc/mjolnir/certs/startupcentral.build/privkey.pem"

      [[cert]]
      host = "zine.identikey.io"
      cert = "/etc/mjolnir/certs/zine.identikey.io/fullchain.pem"
      key = "/etc/mjolnir/certs/zine.identikey.io/privkey.pem"
      """

      pid = Fake.start()
      with_toml(pid, toml)
      # make the cert files readable so cert_info runs
      Agent.update(pid, fn s ->
        put_in(s, [:files, "/etc/mjolnir/certs/startupcentral.build/fullchain.pem"], @cert_pem)
      end)

      assert {:ok, certs} = Certs.list(Fake.opts(pid))
      hosts = Enum.map(certs, & &1.host)
      assert "startupcentral.build" in hosts
      assert "zine.identikey.io" in hosts

      sc = Enum.find(certs, &(&1.host == "startupcentral.build"))
      assert sc.cert_path == "/etc/mjolnir/certs/startupcentral.build/fullchain.pem"
      assert sc.issuer == "Test CA"
      assert sc.not_after == "Jan 1 00:00:00 2030 GMT"
    end

    test "returns [] when there are no cert blocks" do
      pid = Fake.start()
      with_toml(pid, @base_toml)
      assert {:ok, []} = Certs.list(Fake.opts(pid))
    end
  end

  # ==========================================================================
  # remove/2
  # ==========================================================================

  describe "remove/2" do
    setup do
      toml = """
      [[domain]]
      suffix = "startupcentral.build"

      [[cert]]
      host = "startupcentral.build"
      cert = "/etc/mjolnir/certs/startupcentral.build/fullchain.pem"
      key = "/etc/mjolnir/certs/startupcentral.build/privkey.pem"

      [[domain]]
      suffix = "identikey.io"
      """

      pid = Fake.start()
      with_toml(pid, toml)
      {:ok, pid: pid}
    end

    test "removes the [[cert]] block and reloads, leaving [[domain]] by default", %{pid: pid} do
      assert {:ok, :removed} = Certs.remove("startupcentral.build", Fake.opts(pid))
      toml = Fake.toml(pid)
      refute toml =~ ~s(host = "startupcentral.build")
      # domain kept by default
      assert toml =~ ~s(suffix = "startupcentral.build")
      # other blocks untouched
      assert toml =~ ~s(suffix = "identikey.io")
      assert Fake.reloads(pid) == 1
    end

    test "also removes the [[domain]] when :remove_domain is set", %{pid: pid} do
      assert {:ok, :removed} =
               Certs.remove("startupcentral.build", [remove_domain: true] ++ Fake.opts(pid))

      toml = Fake.toml(pid)
      refute toml =~ ~s(suffix = "startupcentral.build")
      assert toml =~ ~s(suffix = "identikey.io")
    end

    test "GCs the cert dir when :gc is set", %{pid: pid} do
      Agent.update(pid, fn s ->
        put_in(s, [:files, "/etc/mjolnir/certs/startupcentral.build/fullchain.pem"], @cert_pem)
      end)

      assert {:ok, :removed} = Certs.remove("startupcentral.build", [gc: true] ++ Fake.opts(pid))
      assert "/etc/mjolnir/certs/startupcentral.build" in Fake.removed(pid)
      assert Fake.file(pid, "/etc/mjolnir/certs/startupcentral.build/fullchain.pem") == nil
    end

    test "returns {:ok, :absent} when no cert entry exists", %{pid: pid} do
      assert {:ok, :absent} = Certs.remove("nonexistent.example.com", Fake.opts(pid))
      assert Fake.reloads(pid) == 0
    end
  end
end
