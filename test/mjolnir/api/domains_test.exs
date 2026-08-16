defmodule Mjolnir.API.DomainsTest do
  use ExUnit.Case, async: true

  alias Mjolnir.API.Domains
  alias Mjolnir.Deploy.Registry.Entry

  @apexes ["identikey.io", "vm.worldtree.network"]

  defp entry(attrs) do
    struct(
      Entry,
      Map.merge(
        %{
          app_name: "zine",
          release_snapshot: "deploy-rel1",
          service_vm_id: "svc-1",
          url: "https://z-3000.vm.test",
          port: 3000,
          custom_domain: nil,
          updated_at: 1
        },
        attrs
      )
    )
  end

  # Fake ops backed by an Agent that mirrors a one-app registry.
  defp fake_ops(agent, opts) do
    running = Keyword.get(opts, :running, ["svc-1"])
    cert = Keyword.get(opts, :cert, false)

    %{
      registry_get: fn app ->
        case Agent.get(agent, &Map.get(&1, app)) do
          nil -> {:error, :not_found}
          e -> {:ok, e}
        end
      end,
      registry_put: fn app, attrs ->
        e = struct(Entry, Map.merge(%{app_name: app, updated_at: 2}, attrs))
        Agent.update(agent, &Map.put(&1, app, e))
        {:ok, e}
      end,
      registry_list: fn -> Agent.get(agent, &Map.values(&1)) end,
      reconcile: fn -> Agent.update(agent, &Map.put(&1, :__reconciled__, true)) end,
      apexes: fn -> @apexes end,
      running_vm_ids: fn -> running end,
      ip_resolver: fn _vm -> "10.0.0.5" end,
      cert_present: fn _fqdn -> cert end,
      http01_ready: fn fqdn -> is_binary(fqdn) and not String.starts_with?(fqdn, "*.") end
    }
  end

  defp reconciled?(agent), do: Agent.get(agent, &Map.get(&1, :__reconciled__, false))

  setup do
    {:ok, agent} = start_supervised({Agent, fn -> %{"zine" => entry(%{})} end})
    %{agent: agent}
  end

  describe "set_domain/3" do
    test "merges custom_domain in, preserving the rest of the entry", %{agent: agent} do
      ops = fake_ops(agent, cert: true)

      assert {:ok, res} =
               Domains.set_domain("zine", "zine.identikey.io", ops: ops)

      assert res == %{
               app: "zine",
               fqdn: "zine.identikey.io",
               backend: "10.0.0.5:3000",
               apex_registered: true,
               cert_present: true
             }

      # The other fields survived the merge-aware put.
      {:ok, e} = ops.registry_get.("zine")
      assert e.custom_domain == "zine.identikey.io"
      assert e.release_snapshot == "deploy-rel1"
      assert e.service_vm_id == "svc-1"
      assert e.port == 3000
      assert reconciled?(agent)
    end

    test "rejects an fqdn whose apex is not configured, without writing", %{agent: agent} do
      ops = fake_ops(agent, [])

      assert {:error, {:apex_not_registered, "zine.example.com", @apexes}} =
               Domains.set_domain("zine", "zine.example.com", ops: ops)

      {:ok, e} = ops.registry_get.("zine")
      assert e.custom_domain == nil
      refute reconciled?(agent)
    end

    test "404s for an unknown app", %{agent: agent} do
      ops = fake_ops(agent, [])
      assert {:error, :not_found} = Domains.set_domain("nope", "nope.identikey.io", ops: ops)
    end
  end

  describe "remove_domain/2" do
    test "clears custom_domain (merge-aware) and reconciles", %{agent: agent} do
      Agent.update(agent, &Map.put(&1, "zine", entry(%{custom_domain: "zine.identikey.io"})))
      ops = fake_ops(agent, [])

      assert {:ok, %{app: "zine", removed: true}} = Domains.remove_domain("zine", ops: ops)

      {:ok, e} = ops.registry_get.("zine")
      assert e.custom_domain == nil
      assert e.release_snapshot == "deploy-rel1"
      assert reconciled?(agent)
    end

    test "404s for an unknown app", %{agent: agent} do
      ops = fake_ops(agent, [])
      assert {:error, :not_found} = Domains.remove_domain("nope", ops: ops)
    end
  end

  describe "list_apps/1" do
    test "joins live backend only for running VMs", %{agent: agent} do
      ops = fake_ops(agent, running: ["svc-1"])
      assert [app] = Domains.list_apps(ops: ops)
      assert app.app_name == "zine"
      assert app.backend == "10.0.0.5:3000"
      assert app.port == 3000
    end

    test "nils the backend when the VM is not running/local", %{agent: agent} do
      ops = fake_ops(agent, running: [])
      assert [app] = Domains.list_apps(ops: ops)
      assert app.backend == nil
    end

    test "apex_registered is nil when the app has no custom_domain", %{agent: agent} do
      ops = fake_ops(agent, [])
      assert [app] = Domains.list_apps(ops: ops)
      assert app.custom_domain == nil
      assert app.apex_registered == nil
      assert app.cert_present == nil
      assert app.http01_ready == nil
    end

    test "apex_registered is true when custom_domain's apex is configured", %{agent: agent} do
      Agent.update(agent, &Map.put(&1, "zine", entry(%{custom_domain: "zine.identikey.io"})))
      ops = fake_ops(agent, cert: true)

      assert [app] = Domains.list_apps(ops: ops)
      assert app.apex_registered == true
      assert app.cert_present == true
      assert app.http01_ready == true
    end

    test "cert_present and http01_ready report per-fqdn when a domain is set", %{agent: agent} do
      Agent.update(agent, &Map.put(&1, "zine", entry(%{custom_domain: "zine.identikey.io"})))
      ops = fake_ops(agent, cert: false)

      assert [app] = Domains.list_apps(ops: ops)
      assert app.cert_present == false
      assert app.http01_ready == true
    end

    test "apex_registered is false when the apex is missing — surfaces the mjolnir-1pk drop via GET /api/apps",
         %{agent: agent} do
      # This is exactly the startupcentral.build failure mode: the entry is
      # registered with a custom_domain (Deploy.Registry reports success), but
      # its apex fell out of :gateway_apexes, so RouteReconciler drops the
      # route. Before this fix nothing surfaced that beyond a log line.
      Agent.update(
        agent,
        &Map.put(&1, "zine", entry(%{custom_domain: "startupcentral.build"}))
      )

      ops = fake_ops(agent, [])

      assert [app] = Domains.list_apps(ops: ops)
      assert app.custom_domain == "startupcentral.build"
      assert app.apex_registered == false
    end
  end
end
