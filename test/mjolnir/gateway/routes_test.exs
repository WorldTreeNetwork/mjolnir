defmodule Mjolnir.Gateway.RoutesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mjolnir.Deploy.Registry.Entry
  alias Mjolnir.Gateway.Routes
  alias Mjolnir.Gateway.Routes.Route

  @apexes ["vm.worldtree.network", "worldtree.network", "identikey.io"]

  # Deterministic stub IP resolver — never touches Network.allocate_ip.
  defp ip(vm_id), do: "10.0.0." <> String.slice(vm_id, -1, 1)
  defp resolver, do: &ip/1

  defp entry(attrs) do
    struct!(
      %Entry{app_name: "app", release_snapshot: "snap", updated_at: 0},
      attrs
    )
  end

  describe "split_fqdn/2 — longest-suffix apex match" do
    test "splits subdomain from a configured apex" do
      assert Routes.split_fqdn("zine.identikey.io", @apexes) == {:ok, {"zine", "identikey.io"}}
    end

    test "picks the LONGEST matching apex" do
      # "vm.worldtree.network" is a longer suffix than "worldtree.network".
      assert Routes.split_fqdn("foo.vm.worldtree.network", @apexes) ==
               {:ok, {"foo", "vm.worldtree.network"}}

      # Falls back to the shorter apex when the longer one doesn't match.
      assert Routes.split_fqdn("foo.worldtree.network", @apexes) ==
               {:ok, {"foo", "worldtree.network"}}
    end

    test "multi-label subdomain is preserved" do
      assert Routes.split_fqdn("a.b.identikey.io", @apexes) == {:ok, {"a.b", "identikey.io"}}
    end

    test "returns :no_apex when nothing matches" do
      assert Routes.split_fqdn("zine.example.com", @apexes) == {:error, :no_apex}
    end

    test "does not match a non-dot-boundary suffix" do
      # "notidentikey.io" must NOT match apex "identikey.io".
      assert Routes.split_fqdn("notidentikey.io", @apexes) == {:error, :no_apex}
    end
  end

  describe "desired_specs/2 — union of registry custom_domain + extra_domains" do
    test "includes registry entries with custom_domain + port" do
      entries = [
        entry(
          app_name: "zine",
          service_vm_id: "vm-1",
          custom_domain: "zine.identikey.io",
          port: 3000
        ),
        entry(app_name: "nodomain", service_vm_id: "vm-2")
      ]

      specs = Routes.desired_specs(entries, [])
      assert specs == [%{fqdn: "zine.identikey.io", vm_id: "vm-1", port: 3000, app_name: "zine"}]
    end

    test "includes extra_domains entries (vm_id form)" do
      specs =
        Routes.desired_specs([], [%{fqdn: "blog.identikey.io", vm_id: "vm-9", port: 4000}])

      # No app_name resolvable — falls back to the vm_id (mjolnir-1pk: never nil,
      # so a dropped-route warning always has something to name).
      assert specs == [
               %{fqdn: "blog.identikey.io", vm_id: "vm-9", port: 4000, app_name: "vm-9"}
             ]
    end

    test "extra_domains app_name form resolves vm_id from registry" do
      entries = [entry(app_name: "shop", service_vm_id: "vm-shop")]
      specs = Routes.desired_specs(entries, [%{fqdn: "shop.identikey.io", app_name: "shop"}])

      # Default port 3000 applied.
      assert specs == [
               %{fqdn: "shop.identikey.io", vm_id: "vm-shop", port: 3000, app_name: "shop"}
             ]
    end

    test "registry wins on fqdn collision with extra_domains" do
      entries = [
        entry(
          app_name: "zine",
          service_vm_id: "vm-reg",
          custom_domain: "zine.identikey.io",
          port: 3000
        )
      ]

      extra = [%{fqdn: "zine.identikey.io", vm_id: "vm-extra", port: 9999}]
      specs = Routes.desired_specs(entries, extra)

      assert specs == [
               %{fqdn: "zine.identikey.io", vm_id: "vm-reg", port: 3000, app_name: "zine"}
             ]
    end

    test "skips malformed extra_domains entries" do
      assert Routes.desired_specs([], [%{fqdn: "x.identikey.io"}]) == []
      assert Routes.desired_specs([], ["not a map"]) == []
    end
  end

  describe "build_routes/5" do
    test "emits a route only for running, local, apex-matching VMs" do
      entries = [
        entry(
          app_name: "zine",
          service_vm_id: "vm-1",
          custom_domain: "zine.identikey.io",
          port: 3000
        )
      ]

      routes = Routes.build_routes(entries, [], ["vm-1"], @apexes, resolver())

      assert routes == [
               %Route{apex: "identikey.io", subdomain: "zine", backend: "10.0.0.1:3000"}
             ]
    end

    test "skips a VM that is not running/local" do
      entries = [
        entry(
          app_name: "zine",
          service_vm_id: "vm-1",
          custom_domain: "zine.identikey.io",
          port: 3000
        )
      ]

      # vm-1 absent from the running set → no route.
      assert Routes.build_routes(entries, [], ["vm-other"], @apexes, resolver()) == []
    end

    test "skips a fqdn whose apex is not configured" do
      extra = [%{fqdn: "app.example.com", vm_id: "vm-1", port: 3000}]
      assert Routes.build_routes([], extra, ["vm-1"], @apexes, resolver()) == []
    end

    test "a correctly-configured app still produces exactly the route it produces today (mjolnir-1pk)" do
      # Regression guard: the fix must not perturb the happy path.
      entries = [
        entry(
          app_name: "zine",
          service_vm_id: "vm-1",
          custom_domain: "zine.identikey.io",
          port: 3000
        )
      ]

      log =
        capture_log(fn ->
          routes = Routes.build_routes(entries, [], ["vm-1"], @apexes, resolver())

          assert routes == [
                   %Route{apex: "identikey.io", subdomain: "zine", backend: "10.0.0.1:3000"}
                 ]
        end)

      refute log =~ "DROPPING"
    end

    test "an app whose apex is missing produces no route AND a warning naming the app, domain, needed apex, and configured apexes (mjolnir-1pk)" do
      entries = [
        entry(
          app_name: "startupcentral",
          service_vm_id: "vm-sc",
          custom_domain: "startupcentral.build",
          port: 3000
        )
      ]

      log =
        capture_log(fn ->
          assert Routes.build_routes(entries, [], ["vm-sc"], @apexes, resolver()) == []
        end)

      # Assert the facts an operator needs mid-outage, not the sentence shape:
      # which app, which domain, what is actually configured, and the concrete
      # fix. Coupling to phrasing makes the warning painful to improve.
      assert log =~ "DROPPING route for app startupcentral"
      assert log =~ "startupcentral.build"
      assert log =~ inspect(@apexes)
      assert log =~ "Add startupcentral.build to :gateway_apexes"
      assert log =~ "config/config.exs"

      # A bare apex has no subdomain to strip, so the fix is stated outright.
      # Anything hedging here would mean the exact/guess split broke.
      refute log =~ "guess"
    end

    test "a deeper fqdn's apex is offered as a guess, not asserted (mjolnir-1pk)" do
      # The last-two-labels heuristic cannot know where the operator meant the
      # subdomain to end, and is plainly wrong for multi-part TLDs. Saying so
      # beats sending someone to add the wrong apex during an outage.
      entries = [
        entry(
          app_name: "deep",
          service_vm_id: "vm-d",
          custom_domain: "a.b.example.co.uk",
          port: 3000
        )
      ]

      log =
        capture_log(fn ->
          assert Routes.build_routes(entries, [], ["vm-d"], @apexes, resolver()) == []
        end)

      assert log =~ "DROPPING route for app deep"
      # co.uk, NOT example.co.uk — the heuristic really is this wrong, which is
      # the whole reason the message hedges instead of instructing.
      assert log =~ "guess says co.uk"
      assert log =~ "may well be wrong"
    end

    test "accepts a MapSet of running ids" do
      extra = [%{fqdn: "app.identikey.io", vm_id: "vm-1", port: 3000}]
      routes = Routes.build_routes([], extra, MapSet.new(["vm-1"]), @apexes, resolver())
      assert [%Route{subdomain: "app", apex: "identikey.io"}] = routes
    end

    test "unions registry + extra and sorts by (apex, subdomain)" do
      entries = [
        entry(
          app_name: "zine",
          service_vm_id: "vm-1",
          custom_domain: "zine.identikey.io",
          port: 3000
        )
      ]

      extra = [
        %{fqdn: "alpha.worldtree.network", vm_id: "vm-2", port: 8080},
        %{fqdn: "beta.identikey.io", vm_id: "vm-3", port: 5000}
      ]

      routes = Routes.build_routes(entries, extra, ["vm-1", "vm-2", "vm-3"], @apexes, resolver())

      assert Enum.map(routes, &{&1.apex, &1.subdomain}) == [
               {"identikey.io", "beta"},
               {"identikey.io", "zine"},
               {"worldtree.network", "alpha"}
             ]
    end
  end

  describe "render_toml/1" do
    test "renders the contracted [[route]] shape" do
      routes = [
        %Route{apex: "identikey.io", subdomain: "zine", backend: "10.237.178.231:3000"}
      ]

      toml = Routes.render_toml(routes)

      assert toml =~ "[[route]]"
      assert toml =~ ~s(apex      = "identikey.io")
      assert toml =~ ~s(subdomain = "zine")
      assert toml =~ ~s(backend   = "10.237.178.231:3000")
      # Header marks it machine-managed.
      assert toml =~ "Managed by Mjolnir.Gateway.Routes"
    end

    test "empty route list renders only the header (no [[route]] blocks)" do
      toml = Routes.render_toml([])
      refute toml =~ "[[route]]"
      assert toml =~ "Managed by Mjolnir.Gateway.Routes"
    end

    test "renders multiple blocks" do
      routes = [
        %Route{apex: "identikey.io", subdomain: "a", backend: "10.0.0.1:3000"},
        %Route{apex: "identikey.io", subdomain: "b", backend: "10.0.0.2:3000"}
      ]

      toml = Routes.render_toml(routes)
      assert toml |> String.split("[[route]]") |> length() == 3
    end
  end

  describe "render_and_reload/1 — fully injected, no infra" do
    test "writes the drop-in atomically and invokes the reload fn" do
      dir =
        Path.join([
          System.tmp_dir!(),
          "mjolnir-gw-routes-test",
          "#{System.unique_integer([:positive])}"
        ])

      path = Path.join(dir, "apps.toml")
      on_exit(fn -> File.rm_rf!(dir) end)

      test_pid = self()

      entries = [
        struct!(%Entry{app_name: "zine", release_snapshot: "s", updated_at: 0},
          service_vm_id: "vm-1",
          custom_domain: "zine.identikey.io",
          port: 3000
        )
      ]

      assert {:ok, routes} =
               Routes.render_and_reload(
                 registry_entries: entries,
                 extra_domains: [],
                 running_vm_ids: ["vm-1"],
                 apexes: @apexes,
                 ip_resolver: &ip/1,
                 path: path,
                 reload: fn -> send(test_pid, :reloaded) end
               )

      assert [%Route{subdomain: "zine"}] = routes
      assert_received :reloaded

      written = File.read!(path)
      assert written =~ ~s(backend   = "10.0.0.1:3000")
      # No lingering tmp file.
      refute File.exists?(path <> ".tmp")
    end
  end

  describe "render_and_reload/1 — destructive-render guards (mjolnir-do5)" do
    # Both of 2026-08-07's startupcentral.build outages were a render that
    # silently dropped a live route. These guard the two mechanisms.

    setup do
      dir =
        Path.join([
          System.tmp_dir!(),
          "mjolnir-gw-do5",
          "#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(dir)
      path = Path.join(dir, "apps.toml")
      on_exit(fn -> File.rm_rf!(dir) end)

      entries = [
        struct!(%Entry{app_name: "sc", release_snapshot: "s", updated_at: 0},
          service_vm_id: "vm-1",
          custom_domain: "startupcentral.build",
          port: 3000
        )
      ]

      %{path: path, entries: entries}
    end

    defp render(path, entries, running, reload \\ fn -> :ok end) do
      Routes.render_and_reload(
        registry_entries: entries,
        extra_domains: [],
        running_vm_ids: running,
        apexes: ["startupcentral.build" | @apexes],
        ip_resolver: &ip/1,
        path: path,
        reload: reload
      )
    end

    test "an UNKNOWN running-VM set never overwrites the file", ctx do
      # Establish a good file first.
      assert {:ok, [_]} = render(ctx.path, ctx.entries, ["vm-1"])
      good = File.read!(ctx.path)
      assert good =~ "startupcentral.build"

      # VM.list could not be determined (one wedged VM is enough — mjolnir-8ie).
      # Returning [] here is what wiped every route; :unknown must be inert.
      test_pid = self()

      assert {:error, :running_vms_unknown} =
               render(ctx.path, ctx.entries, :unknown, fn -> send(test_pid, :reloaded) end)

      assert File.read!(ctx.path) == good, "an inconclusive VM read must not rewrite the file"
      refute_received :reloaded, "and must not reload the gateway"
    end

    test "a genuinely empty running set still renders (so `mj domain rm` works)", ctx do
      assert {:ok, [_]} = render(ctx.path, ctx.entries, ["vm-1"])
      assert {:ok, []} = render(ctx.path, ctx.entries, [])
      refute File.read!(ctx.path) =~ "startupcentral.build"
    end

    test "a render that removes a live route logs it loudly", ctx do
      assert {:ok, [_]} = render(ctx.path, ctx.entries, ["vm-1"])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # The VM is mid-resume, so it is absent from the running set.
          assert {:ok, []} = render(ctx.path, ctx.entries, [])
        end)

      assert log =~ "REMOVES"
      assert log =~ "startupcentral.build"
    end

    test "an unchanged render logs no removal", ctx do
      assert {:ok, [_]} = render(ctx.path, ctx.entries, ["vm-1"])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, [_]} = render(ctx.path, ctx.entries, ["vm-1"])
        end)

      refute log =~ "REMOVES"
    end
  end
end
