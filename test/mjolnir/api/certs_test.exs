defmodule Mjolnir.API.CertsTest do
  # include_cert?/3 reads the shared alias index. Stay synchronous so that
  # root is not swapped by another case while these files exist.
  use ExUnit.Case, async: false

  alias Mjolnir.API.Certs

  @cert "-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----\n"
  @key "-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----\n"

  defp fake_ops(agent) do
    %{
      issue_cmd: fn fqdn ->
        Agent.update(agent, fn s ->
          %{s | issued: [fqdn | s.issued]}
        end)

        {:ok, %{cert: @cert, key: @key, not_after: "2030-01-01T00:00:00Z"}}
      end,
      ensure: fn fqdn, cert, key, opts ->
        Agent.update(agent, fn s ->
          %{s | ensured: [{fqdn, cert, key, opts} | s.ensured]}
        end)

        {:ok, :installed}
      end,
      list_certs: fn ->
        {:ok,
         [
           %{
             host: "taskmaster.dev",
             cert_path: "/etc/mjolnir/certs/taskmaster.dev/fullchain.pem",
             key_path: "/etc/mjolnir/certs/taskmaster.dev/privkey.pem",
             not_after: "Jan 1 00:00:00 2030 GMT",
             issuer: "Test CA",
             sans: ["taskmaster.dev"]
           }
         ]}
      end
    }
  end

  setup do
    {:ok, agent} = start_supervised({Agent, fn -> %{issued: [], ensured: []} end})
    %{agent: agent, ops: fake_ops(agent)}
  end

  describe "issue/2" do
    test "plants via issue_cmd and installs [[cert]] without returning PEMs", %{
      agent: agent,
      ops: ops
    } do
      assert {:ok, res} = Certs.issue("Taskmaster.dev", ops: ops)

      assert res == %{
               fqdn: "taskmaster.dev",
               status: :installed,
               not_after: "2030-01-01T00:00:00Z"
             }

      refute Map.has_key?(res, :cert)
      refute Map.has_key?(res, :key)
      refute Map.has_key?(res, :fullchain)
      refute Map.has_key?(res, :privkey)

      assert Agent.get(agent, & &1.issued) == ["taskmaster.dev"]
      assert [{fqdn, cert, key, opts}] = Agent.get(agent, & &1.ensured)
      assert fqdn == "taskmaster.dev"
      assert cert == @cert
      assert key == @key
      assert opts[:domain] == true
    end

    test "refuses wildcards and never calls issue_cmd", %{agent: agent, ops: ops} do
      assert {:error, :wildcard_not_supported} = Certs.issue("*.taskmaster.dev", ops: ops)
      assert Agent.get(agent, & &1.issued) == []
      assert Agent.get(agent, & &1.ensured) == []
    end

    test "returns issue_cmd failure without calling ensure", %{agent: agent} do
      ops = %{
        issue_cmd: fn _ -> {:error, {:issue_failed, 1, "acme timeout"}} end,
        ensure: fn _, _, _, _ -> flunk("ensure must not run after issue_cmd fails") end,
        list_certs: fn -> {:ok, []} end
      }

      assert {:error, {:issue_failed, 1, "acme timeout"}} =
               Certs.issue("taskmaster.dev", ops: ops)

      assert Agent.get(agent, & &1.ensured) == []
    end

    test "wraps ensure failure after a successful issue_cmd" do
      ops = %{
        issue_cmd: fn _ -> {:ok, %{cert: @cert, key: @key, not_after: nil}} end,
        ensure: fn _, _, _, _ -> {:error, :key_pair_mismatch} end,
        list_certs: fn -> {:ok, []} end
      }

      assert {:error, {:ensure_failed, :key_pair_mismatch}} =
               Certs.issue("taskmaster.dev", ops: ops)
    end
  end

  describe "renew_due/1" do
    @now ~U[2026-09-25 12:00:00Z]

    defp renew_ops(agent, certs) do
      %{
        issue_cmd: fn fqdn ->
          Agent.update(agent, fn s -> %{s | issued: [fqdn | s.issued]} end)
          {:ok, %{cert: @cert, key: @key, not_after: "2030-01-01T00:00:00Z"}}
        end,
        ensure: fn fqdn, cert, key, opts ->
          Agent.update(agent, fn s -> %{s | ensured: [{fqdn, cert, key, opts} | s.ensured]} end)
          {:ok, :installed}
        end,
        list_certs: fn -> {:ok, certs} end
      }
    end

    test "does nothing when every cert is outside the window", %{agent: agent} do
      ops =
        renew_ops(agent, [
          %{host: "taskmaster.dev", not_after: "Jan 1 00:00:00 2030 GMT"}
        ])

      assert {:ok, :none} = Certs.renew_due(now: @now, ops: ops)
      assert Agent.get(agent, & &1.issued) == []
    end

    test "issues only the soonest certificate inside 30 days", %{agent: agent} do
      ops =
        renew_ops(agent, [
          %{host: "fresh.example", not_after: "Jan 1 00:00:00 2030 GMT"},
          %{host: "zine.identikey.io", not_after: "Sep 22 22:42:17 2026 GMT"},
          %{host: "older.example", not_after: "Sep 1 00:00:00 2026 GMT"}
        ])

      assert {:ok, %{fqdn: "older.example", status: :installed}} =
               Certs.renew_due(now: @now, ops: ops)

      assert Agent.get(agent, & &1.issued) == ["older.example"]
    end

    test "treats an unreadable expiry as due and skips wildcards", %{agent: agent} do
      ops =
        renew_ops(agent, [
          %{host: "*.example.com", not_after: "Jan 1 00:00:00 2020 GMT"},
          %{host: "undated.example", not_after: nil}
        ])

      assert {:ok, %{fqdn: "undated.example"}} = Certs.renew_due(now: @now, ops: ops)
    end

    test "a certificate 31 days out is not due", %{agent: agent} do
      ops =
        renew_ops(agent, [
          %{host: "edge.example", not_after: "Oct 26 12:00:00 2026 GMT"}
        ])

      assert {:ok, :none} = Certs.renew_due(now: @now, ops: ops)
    end

    test "a certificate exactly 30 days out is due", %{agent: agent} do
      ops =
        renew_ops(agent, [
          %{host: "edge.example", not_after: "Oct 25 12:00:00 2026 GMT"}
        ])

      assert {:ok, %{fqdn: "edge.example"}} = Certs.renew_due(now: @now, ops: ops)
    end
  end

  describe "list/1" do
    test "strips PEM paths from the public shape", %{ops: ops} do
      assert {:ok, [c]} = Certs.list(ops: ops)
      assert c.host == "taskmaster.dev"
      assert c.not_after == "Jan 1 00:00:00 2030 GMT"
      assert c.issuer == "Test CA"
      assert c.sans == ["taskmaster.dev"]
      refute Map.has_key?(c, :cert_path)
      refute Map.has_key?(c, :key_path)
      refute Map.has_key?(c, :cert)
      refute Map.has_key?(c, :key)
    end
  end

  describe "resolve/2" do
    test "prefers an app when a site alias also exists" do
      entry = %{app_name: "shop", custom_domain: "shop.example.com"}

      ops = %{
        app_for_domain: fn _ -> entry end,
        read_alias: fn _ -> flunk("site path must not run when an app owns the host") end,
        classify: fn _ -> flunk("classify must not run on the app path") end,
        issue_cmd: fn _ -> flunk("resolve does not issue") end,
        ensure: fn _, _, _, _ -> flunk("resolve does not install") end,
        list_certs: fn -> {:ok, []} end
      }

      assert {:app, ^entry} = Certs.resolve("shop.example.com", ops: ops)
    end

    test "a live alias classifies before it is a site subject" do
      ops = %{
        app_for_domain: fn _ -> nil end,
        read_alias: fn "blog.example.com" -> {:ok, {"fp", "blog"}} end,
        classify: fn "blog.example.com" -> {:ok, :reject} end,
        issue_cmd: fn _ -> flunk("resolve does not issue") end,
        ensure: fn _, _, _, _ -> flunk("resolve does not install") end,
        list_certs: fn -> {:ok, []} end
      }

      assert {:site, "blog.example.com"} = Certs.resolve("blog.example.com", ops: ops)
    end

    test "local or iroh is host_routed_elsewhere" do
      ops = fn kind ->
        %{
          app_for_domain: fn _ -> nil end,
          read_alias: fn _ -> {:ok, {"fp", "blog"}} end,
          classify: fn _ -> {:ok, kind} end,
          issue_cmd: fn _ -> flunk("no LE") end,
          ensure: fn _, _, _, _ -> flunk("no install") end,
          list_certs: fn -> {:ok, []} end
        }
      end

      assert {:error, :host_routed_elsewhere} =
               Certs.resolve("blog.example.com", ops: ops.(:iroh))

      assert {:error, :host_routed_elsewhere} =
               Certs.resolve("blog.example.com", ops: ops.(:local))
    end

    test "parked still resolves as a site" do
      ops = %{
        app_for_domain: fn _ -> nil end,
        read_alias: fn _ -> {:ok, {"fp", "blog"}} end,
        classify: fn _ -> {:ok, :parked} end,
        issue_cmd: fn _ -> flunk("resolve does not issue") end,
        ensure: fn _, _, _, _ -> flunk("resolve does not install") end,
        list_certs: fn -> {:ok, []} end
      }

      assert {:site, "blog.example.com"} = Certs.resolve("blog.example.com", ops: ops)
    end

    test "an unreadable alias index is not a miss" do
      ops = %{
        app_for_domain: fn _ -> nil end,
        read_alias: fn _ -> {:error, :unreadable} end,
        classify: fn _ -> flunk("classify must not run") end,
        issue_cmd: fn _ -> flunk("no LE") end,
        ensure: fn _, _, _, _ -> flunk("no install") end,
        list_certs: fn -> {:ok, []} end
      }

      assert {:error, :alias_index_unreadable} =
               Certs.resolve("blog.example.com", ops: ops)
    end

    test "a missing alias is name_not_found" do
      ops = %{
        app_for_domain: fn _ -> nil end,
        read_alias: fn _ -> :not_found end,
        classify: fn _ -> flunk("classify must not run") end,
        issue_cmd: fn _ -> flunk("no LE") end,
        ensure: fn _, _, _, _ -> flunk("no install") end,
        list_certs: fn -> {:ok, []} end
      }

      assert {:error, :name_not_found} = Certs.resolve("gone.example.com", ops: ops)
    end

    test "an unclassifiable gateway config fails closed" do
      ops = %{
        app_for_domain: fn _ -> nil end,
        read_alias: fn _ -> {:ok, {"fp", "blog"}} end,
        classify: fn _ -> {:error, :gateway_config_unreadable} end,
        issue_cmd: fn _ -> flunk("no LE") end,
        ensure: fn _, _, _, _ -> flunk("no install") end,
        list_certs: fn -> {:ok, []} end
      }

      assert {:error, :gateway_config_unreadable} =
               Certs.resolve("blog.example.com", ops: ops)
    end
  end

  describe "renew_due/1 site subjects" do
    test "reinstalls a stranger with domain insertion off", %{agent: agent} do
      ops =
        renew_ops(agent, [
          %{host: "zine.identikey.io", not_after: "Sep 1 00:00:00 2026 GMT"}
        ])
        |> Map.merge(%{
          app_for_domain: fn _ -> nil end,
          read_alias: fn _ -> :not_found end
        })

      assert {:ok, %{fqdn: "zine.identikey.io"}} = Certs.renew_due(now: @now, ops: ops)
      assert [{_, _, _, opts}] = Agent.get(agent, & &1.ensured)
      assert opts[:domain] == false
    end

    test "reinstalls a live alias with domain insertion off", %{agent: agent} do
      ops =
        renew_ops(agent, [
          %{host: "blog.example.com", not_after: "Sep 1 00:00:00 2026 GMT"}
        ])
        |> Map.merge(%{
          app_for_domain: fn _ -> nil end,
          read_alias: fn _ -> {:ok, {"fp", "blog"}} end,
          classify: fn _ -> flunk("renewal does not re-apply the 409") end
        })

      assert {:ok, %{fqdn: "blog.example.com"}} = Certs.renew_due(now: @now, ops: ops)
      assert [{_, _, _, opts}] = Agent.get(agent, & &1.ensured)
      assert opts[:domain] == false
    end

    test "does not call Let's Encrypt when the alias index is unreadable", %{agent: agent} do
      ops =
        renew_ops(agent, [
          %{host: "blog.example.com", not_after: "Sep 1 00:00:00 2026 GMT"}
        ])
        |> Map.merge(%{
          app_for_domain: fn _ -> nil end,
          read_alias: fn _ -> {:error, :eisdir} end
        })

      assert {:error, :alias_index_unreadable} = Certs.renew_due(now: @now, ops: ops)
      assert Agent.get(agent, & &1.issued) == []
      assert Agent.get(agent, & &1.ensured) == []
    end

    test "an app host renews even when the alias index is unreadable", %{agent: agent} do
      ops =
        renew_ops(agent, [
          %{host: "shop.example.com", not_after: "Sep 1 00:00:00 2026 GMT"}
        ])
        |> Map.merge(%{
          app_for_domain: fn _ -> %{app_name: "shop"} end,
          read_alias: fn _ -> flunk("app renewal does not read the alias index") end
        })

      assert {:ok, %{fqdn: "shop.example.com"}} = Certs.renew_due(now: @now, ops: ops)
      assert [{_, _, _, opts}] = Agent.get(agent, & &1.ensured)
      assert opts[:domain] == false
    end
  end

  describe "include_cert?/3" do
    setup do
      root = Mjolnir.SecretStore.root()
      n = System.unique_integer([:positive])
      site = "blog-#{n}.example.com"
      app = "shop-#{n}.example.com"
      hand = "zine-#{n}.identikey.io"

      write_alias!(root, site, ~s({"fp":"abc","site":"blog"}))
      write_alias_dir!(root, "bad-#{n}.example.com")

      on_exit(fn ->
        File.rm(alias_path(root, site))
        File.rm_rf(alias_path(root, "bad-#{n}.example.com"))
      end)

      %{site: site, app: app, hand: hand, bad: "bad-#{n}.example.com"}
    end

    test "a non-operator sees a live alias and an owned app, not a stranger", ctx do
      owned = MapSet.new([ctx.app])
      user = %{user_id: "person"}

      assert Certs.include_cert?(%{host: ctx.site}, user, owned)
      assert Certs.include_cert?(%{host: ctx.app}, user, owned)
      refute Certs.include_cert?(%{host: ctx.hand}, user, owned)
      refute Certs.include_cert?(%{host: ctx.bad}, user, owned)
    end

    test "the operator sees a host whose alias index is unreadable", ctx do
      user = %{user_id: "localhost"}
      assert Certs.include_cert?(%{host: ctx.bad}, user, MapSet.new())
    end
  end

  defp alias_path(root, fqdn), do: Path.join([root, "_index", "aliases", fqdn])

  defp write_alias!(root, fqdn, body) do
    path = alias_path(root, fqdn)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  defp write_alias_dir!(root, fqdn) do
    path = alias_path(root, fqdn)
    File.mkdir_p!(path)
  end
end
