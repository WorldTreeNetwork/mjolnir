defmodule Mjolnir.Gateway.Routes do
  @moduledoc """
  Generates the gateway's local-route drop-in so co-located VMs are served over
  direct host→guest TCP instead of paying Iroh's ~7s cold-start.

  See `docs/plans/gateway-local-routing.md` (Phase 2). The Rust `mjolnir-gateway`
  reads `/etc/mjolnir/gateway.d/*.toml` and SIGHUP-reloads them, merging any
  `[[route]]` blocks over the hand-maintained base `gateway.toml`. This module
  owns the Elixir side: it renders that drop-in and triggers the reload.

  ## Contract with the gateway

  We write exactly one file (`:gateway_routes_path`, default
  `/etc/mjolnir/gateway.d/apps.toml`) containing only `[[route]]` blocks with
  three keys:

      [[route]]
      apex      = "identikey.io"
      subdomain = "zine"
      backend   = "10.237.178.231:3000"

  Drop-ins **cannot declare apexes** — `apex` must be one of the gateway's
  configured `[[domain]]` apexes. So a custom-domain fqdn is split into
  `(subdomain, apex)` by matching the **longest** configured apex suffix
  (`:gateway_apexes`). A route is only emitted for a VM that is currently
  **running and local** (present in `Mjolnir.VM.list/0`); dormant/stopped VMs
  are skipped. The backend is `"<guest_ip>:<port>"` where
  `guest_ip = Mjolnir.Network.allocate_ip(vm_id)` (deterministic).

  ## Desired-route sources (union)

  1. `Mjolnir.Deploy.Registry` entries carrying a `custom_domain` + `port`
     (the forward path for Deploy-managed apps).
  2. `:gateway_extra_domains` — a static config list for manually-provisioned
     apps (e.g. `zine`, which is not in `Deploy.Registry`). Each entry is
     `%{fqdn: ..., port: ..., vm_id: ...}` or `%{fqdn: ..., port: ..., app_name: ...}`
     (the `app_name` form resolves `vm_id` from the registry).

  ## Testability

  The pure pipeline — `build_routes/5` → `render_toml/1` — takes everything as
  arguments (registry entries, extra domains, running vm ids, apexes, an
  `ip_resolver`), so it needs no VMs, no filesystem, and no root. `render_and_reload/1`
  wires the real sources in but every side effect (which VMs run, IP resolution,
  the file path, the reload command) is injectable.
  """

  require Logger

  @default_apexes ["vm.worldtree.network", "worldtree.network", "identikey.io"]
  @default_path "/etc/mjolnir/gateway.d/apps.toml"
  @default_port 3000

  defmodule Route do
    @moduledoc "A single rendered `[[route]]`: `(apex, subdomain) → backend`."

    @type t :: %__MODULE__{apex: String.t(), subdomain: String.t(), backend: String.t()}

    @enforce_keys [:apex, :subdomain, :backend]
    defstruct [:apex, :subdomain, :backend]
  end

  # ==========================================================================
  # Pure pipeline (unit-testable, no side effects)
  # ==========================================================================

  @typedoc "A desired route intent before VM/apex resolution."
  @type spec :: %{fqdn: String.t(), vm_id: String.t(), port: pos_integer(), app_name: String.t()}

  @doc """
  Build the desired route specs from the union of registry entries (those with a
  `custom_domain` + `port`) and the static `extra_domains` config list.

  Deduplicates by `fqdn` (registry entries take precedence). Pure: `app_name`
  references in `extra_domains` are resolved against the passed `registry_entries`.

  Each spec carries an `:app_name` — best-effort, so a dropped route can name
  the app it belongs to (mjolnir-1pk) rather than just an fqdn. Falls back to
  the `vm_id` when no app name can be resolved.
  """
  @spec desired_specs([Mjolnir.Deploy.Registry.Entry.t()], [map()]) :: [spec()]
  def desired_specs(registry_entries, extra_domains) do
    from_registry =
      for e <- registry_entries,
          is_binary(e.custom_domain),
          e.custom_domain != "",
          is_integer(e.port),
          is_binary(e.service_vm_id) do
        %{fqdn: e.custom_domain, vm_id: e.service_vm_id, port: e.port, app_name: e.app_name}
      end

    from_extra =
      extra_domains
      |> Enum.map(&normalize_extra(&1, registry_entries))
      |> Enum.reject(&is_nil/1)

    # Registry first so it wins on an fqdn collision with extra_domains.
    Enum.uniq_by(from_registry ++ from_extra, & &1.fqdn)
  end

  @doc """
  Resolve desired specs into concrete `Route` structs.

  Skips (with a `Logger.warning`) any spec whose VM is not in `running_vm_ids`
  (not running/local) or whose fqdn matches no configured apex. `running_vm_ids`
  may be a list or a `MapSet`. `ip_resolver` maps a `vm_id` to its guest IP.
  Result is sorted by `(apex, subdomain)` for deterministic output.
  """
  @spec build_routes(
          [Mjolnir.Deploy.Registry.Entry.t()],
          [map()],
          [String.t()] | MapSet.t(),
          [
            String.t()
          ],
          (String.t() -> String.t())
        ) :: [Route.t()]
  def build_routes(registry_entries, extra_domains, running_vm_ids, apexes, ip_resolver) do
    running = running_set(running_vm_ids)

    registry_entries
    |> desired_specs(extra_domains)
    |> Enum.flat_map(&spec_to_route(&1, running, apexes, ip_resolver))
    |> Enum.sort_by(&{&1.apex, &1.subdomain})
  end

  @doc """
  Split `fqdn` into `{subdomain, apex}` against `apexes`, matching the **longest**
  configured apex suffix. Returns `{:ok, {subdomain, apex}}` or `{:error, :no_apex}`.

      iex> Mjolnir.Gateway.Routes.split_fqdn("zine.identikey.io", ["identikey.io"])
      {:ok, {"zine", "identikey.io"}}
  """
  @spec split_fqdn(String.t(), [String.t()]) ::
          {:ok, {String.t(), String.t()}} | {:error, :no_apex}
  def split_fqdn(fqdn, apexes) do
    match =
      apexes
      |> Enum.filter(fn apex -> fqdn == apex or String.ends_with?(fqdn, "." <> apex) end)
      |> Enum.sort_by(&String.length/1, :desc)
      |> List.first()

    case match do
      nil -> {:error, :no_apex}
      ^fqdn -> {:ok, {"", fqdn}}
      apex -> {:ok, {String.replace_suffix(fqdn, "." <> apex, ""), apex}}
    end
  end

  @doc "Render `[[route]]` blocks as a TOML drop-in string."
  @spec render_toml([Route.t()]) :: String.t()
  def render_toml(routes) do
    header =
      "# Managed by Mjolnir.Gateway.Routes — DO NOT EDIT BY HAND.\n" <>
        "# Regenerated on VM lifecycle + deploy-cutover events. Route blocks only.\n"

    body =
      Enum.map_join(routes, fn r ->
        """

        [[route]]
        apex      = #{quote_str(r.apex)}
        subdomain = #{quote_str(r.subdomain)}
        backend   = #{quote_str(r.backend)}
        """
      end)

    header <> body
  end

  # ==========================================================================
  # Side-effecting entry point (injectable)
  # ==========================================================================

  @doc """
  Render the drop-in and reload the gateway.

  Every source/effect is injectable via `opts` (defaults wire the real system):

    * `:registry_entries` — `[Registry.Entry.t()]` (default `Deploy.Registry.list/0`)
    * `:extra_domains` — `[map()]` (default `:gateway_extra_domains` config)
    * `:running_vm_ids` — list/MapSet of running+local vm_ids (default from `VM.list/0`)
    * `:apexes` — configured gateway apexes (default `:gateway_apexes` config)
    * `:ip_resolver` — `(vm_id -> ip)` (default `Network.allocate_ip/1`)
    * `:path` — drop-in file path (default `:gateway_routes_path` config)
    * `:reload` — `(-> any)` reload effect (default `systemctl reload mjolnir-gateway`)

  Returns `{:ok, routes}` or `{:error, reason}` (file write failure).
  """
  @spec render_and_reload(keyword()) :: {:ok, [Route.t()]} | {:error, term()}
  def render_and_reload(opts \\ []) do
    apexes = Keyword.get(opts, :apexes, configured_apexes())
    registry_entries = Keyword.get_lazy(opts, :registry_entries, &default_registry_entries/0)
    extra_domains = Keyword.get(opts, :extra_domains, configured_extra_domains())
    running_vm_ids = Keyword.get_lazy(opts, :running_vm_ids, &default_running_vm_ids/0)
    ip_resolver = Keyword.get(opts, :ip_resolver, &Mjolnir.Network.allocate_ip/1)
    path = Keyword.get(opts, :path, configured_path())
    reload = Keyword.get(opts, :reload, &default_reload/0)

    if running_vm_ids == :unknown do
      # Keep whatever is on disk: publishing a route-less file because we could
      # not read VM state is strictly worse than serving slightly stale routes
      # (mjolnir-do5).
      Logger.warning(
        "Gateway.Routes: running-VM set is unknown; keeping existing #{path} rather than " <>
          "rendering a possible wipe"
      )

      {:error, :running_vms_unknown}
    else
      routes = build_routes(registry_entries, extra_domains, running_vm_ids, apexes, ip_resolver)
      toml = render_toml(routes)
      warn_on_removed_routes(path, routes)

      case write_atomic(path, toml) do
        :ok ->
          reload.()
          Logger.info("Gateway.Routes: wrote #{length(routes)} route(s) to #{path}")
          {:ok, routes}

        {:error, reason} = err ->
          Logger.error("Gateway.Routes: failed to write #{path}: #{inspect(reason)}")
          err
      end
    end
  end

  # A render that DROPS a route is the failure mode behind both of 2026-08-07's
  # outages, and in each case the only trace was a single line buried among
  # normal startup chatter. Name it explicitly, with the fqdns lost, so it is
  # greppable and alertable.
  defp warn_on_removed_routes(path, new_routes) do
    previous = existing_route_keys(path)
    current = MapSet.new(new_routes, &route_key/1)
    removed = MapSet.difference(previous, current)

    unless Enum.empty?(removed) do
      Logger.warning(
        "Gateway.Routes: this render REMOVES #{MapSet.size(removed)} existing route(s): " <>
          "#{Enum.join(Enum.sort(removed), ", ")} — customer traffic to those hosts will 400 " <>
          "until they come back"
      )
    end
  end

  defp route_key(%Route{apex: apex, subdomain: sub}) do
    if sub in [nil, ""], do: apex, else: "#{sub}.#{apex}"
  end

  # Recover the fqdns from the file we last wrote. Cheap line scan rather than a
  # TOML parse: this file's shape is ours and stable, and a parse failure here
  # must never block a render.
  defp existing_route_keys(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("[[route]]")
        |> Enum.drop(1)
        |> Enum.map(fn block ->
          apex = capture_toml_value(block, "apex")
          sub = capture_toml_value(block, "subdomain")
          if sub in [nil, ""], do: apex, else: "#{sub}.#{apex}"
        end)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      {:error, _} ->
        MapSet.new()
    end
  end

  defp capture_toml_value(block, key) do
    case Regex.run(~r/^\s*#{key}\s*=\s*"([^"]*)"/m, block) do
      [_, value] -> value
      _ -> nil
    end
  end

  # ==========================================================================
  # Internals
  # ==========================================================================

  defp normalize_extra(m, registry_entries) when is_map(m) do
    fqdn = Map.get(m, :fqdn) || Map.get(m, "fqdn")
    port = Map.get(m, :port) || Map.get(m, "port") || @default_port
    app_name = Map.get(m, :app_name) || Map.get(m, "app_name")

    vm_id =
      Map.get(m, :vm_id) || Map.get(m, "vm_id") || resolve_app_vm(app_name, registry_entries)

    if is_binary(fqdn) and is_binary(vm_id) and is_integer(port) do
      %{
        fqdn: fqdn,
        vm_id: vm_id,
        port: port,
        app_name: app_name || app_name_for_vm(vm_id, registry_entries) || vm_id
      }
    else
      Logger.warning("Gateway.Routes: skipping malformed extra_domain entry #{inspect(m)}")
      nil
    end
  end

  defp normalize_extra(_other, _entries), do: nil

  defp resolve_app_vm(name, registry_entries) when is_binary(name) do
    Enum.find_value(registry_entries, fn e ->
      if e.app_name == name, do: e.service_vm_id
    end)
  end

  defp resolve_app_vm(_name, _entries), do: nil

  defp app_name_for_vm(vm_id, registry_entries) do
    Enum.find_value(registry_entries, fn e ->
      if e.service_vm_id == vm_id, do: e.app_name
    end)
  end

  defp spec_to_route(spec, running, apexes, ip_resolver) do
    %{fqdn: fqdn, vm_id: vm_id, port: port} = spec
    app_name = Map.get(spec, :app_name, vm_id)

    cond do
      not MapSet.member?(running, vm_id) ->
        Logger.warning(
          "Gateway.Routes: skipping #{fqdn} — VM #{vm_id} is not running/local; no route emitted"
        )

        []

      true ->
        case split_fqdn(fqdn, apexes) do
          {:ok, {subdomain, apex}} ->
            [%Route{apex: apex, subdomain: subdomain, backend: "#{ip_resolver.(vm_id)}:#{port}"}]

          {:error, :no_apex} ->
            # This is the mjolnir-1pk failure mode: a custom_domain whose apex
            # fell out of :gateway_apexes (or was never persisted there) is
            # dropped with NO route and, previously, only a terse one-line
            # warning easy to miss among normal startup chatter. Name the app,
            # the domain, the apex it needs, and what is actually configured so
            # an operator reading logs knows exactly what to fix and where.
            fix =
              case needed_apex(fqdn) do
                {:exact, apex} ->
                  "Add #{apex} to :gateway_apexes in config/config.exs."

                {:guess, apex} ->
                  # Hedge, and say so. A confidently-wrong apex is worse than
                  # an admitted guess when someone is reading this mid-outage:
                  # the heuristic cannot know where the operator intended the
                  # subdomain to end, and it is plainly wrong for multi-part
                  # TLDs — a.b.example.co.uk yields co.uk.
                  "Add the apex this domain sits under to :gateway_apexes in " <>
                    "config/config.exs — a last-two-labels guess says #{apex}, " <>
                    "which may well be wrong; use the apex you actually own."
              end

            Logger.warning(
              "Gateway.Routes: DROPPING route for app #{app_name} — custom_domain " <>
                "#{fqdn} has no apex in :gateway_apexes, which is configured as " <>
                "#{inspect(apexes)}. #{fqdn} will answer 400 (\"Empty subdomain\") " <>
                "until this is fixed. #{fix} Set it durably — a runtime " <>
                "Application.put_env or MJOLNIR_GATEWAY_APEXES override is lost on " <>
                "restart, which is exactly how this broke before."
            )

            []
        end
    end
  end

  # The apex a dropped fqdn needed, tagged with how much we actually know.
  #
  # Two labels or fewer means the fqdn IS the apex — there is no subdomain to
  # strip, so the answer is exact. That is the bare-apex case that caused
  # mjolnir-1pk (`startupcentral.build`). Deeper names are a guess: nothing
  # here knows where the operator intended the subdomain to end, and the
  # last-two-labels heuristic is simply wrong for multi-part TLDs. The caller
  # phrases the two cases differently rather than asserting a guess as fact.
  @spec needed_apex(String.t()) :: {:exact | :guess, String.t()}
  defp needed_apex(fqdn) do
    case String.split(fqdn, ".") do
      labels when length(labels) <= 2 -> {:exact, fqdn}
      labels -> {:guess, labels |> Enum.take(-2) |> Enum.join(".")}
    end
  end

  defp running_set(%MapSet{} = set), do: set
  defp running_set(list) when is_list(list), do: MapSet.new(list)

  # TOML basic string. Our values (domains, "ip:port") contain no quotes or
  # backslashes; escape defensively all the same.
  defp quote_str(s) do
    escaped = s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"" <> escaped <> "\""
  end

  defp write_atomic(path, contents) do
    dir = Path.dirname(path)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         {:ok, io} <- :file.open(tmp, [:raw, :write, :binary]),
         :ok <- :file.write(io, contents),
         :ok <- :file.sync(io),
         :ok <- :file.close(io),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _} = err ->
        _ = File.rm(tmp)
        err

      other ->
        _ = File.rm(tmp)
        {:error, other}
    end
  end

  defp default_reload do
    case System.cmd("systemctl", ["reload", "mjolnir-gateway"], stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Logger.warning(
          "Gateway.Routes: 'systemctl reload mjolnir-gateway' exited #{code}: #{out}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("Gateway.Routes: reload command failed: #{Exception.message(e)}")
      :ok
  end

  defp default_registry_entries do
    Mjolnir.Deploy.Registry.list()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Returns the running VM ids, or `:unknown` if the set could not be determined.
  #
  # Returning `[]` on failure — as this used to — is exactly backwards
  # (mjolnir-do5). VM.list/0 polls every VM GenServer, so a SINGLE wedged VM
  # (mjolnir-8ie / mjolnir-75d) can make the whole call exit; an empty set then
  # renders a file with no routes at all and takes every customer domain down.
  # An inconclusive read must leave the existing routes alone, not publish a
  # wipe. `[]` still means a genuine "nothing is running".
  defp default_running_vm_ids do
    Mjolnir.VM.list()
    |> Enum.filter(&(Map.get(&1, :state) == :running))
    |> Enum.map(& &1.id)
  rescue
    e ->
      Logger.warning("Gateway.Routes: could not list VMs (#{Exception.message(e)})")
      :unknown
  catch
    :exit, reason ->
      Logger.warning("Gateway.Routes: VM.list exited (#{inspect(reason)})")
      :unknown
  end

  defp configured_apexes,
    do: Application.get_env(:mjolnir, :gateway_apexes, @default_apexes)

  defp configured_extra_domains,
    do: Application.get_env(:mjolnir, :gateway_extra_domains, [])

  defp configured_path,
    do: Application.get_env(:mjolnir, :gateway_routes_path, @default_path)
end
