defmodule Mjolnir.API.Domains do
  @moduledoc """
  Custom-domain management for deployed apps (gge.12.2, API half).

  Backs the `PUT/DELETE /api/apps/:app/domain` and `GET /api/apps` endpoints in
  `Mjolnir.API.Router`. All registry mutations are **merge-aware**: the gateway
  route for an app is dropped the moment its registry entry loses `custom_domain`
  + `port` (see `Mjolnir.Gateway.Routes.desired_specs/2`), and `Registry.put`
  builds a *fresh* `Entry` from the attrs it is given — so a naive put that omits
  `release_snapshot`/`service_vm_id`/`url`/`port` would silently strip the app's
  routing. Every write here therefore reads the current entry, merges the change,
  and writes back the full attr set.

  ## Apex validation

  A drop-in route can only name an apex the gateway already declares
  (`:gateway_apexes`, durably overridable via `MJOLNIR_GATEWAY_APEXES`, gge.12.3).
  If the requested fqdn matches no configured apex the reconciler would silently
  emit no route, so `set_domain/3` rejects it up front with
  `{:error, {:apex_not_registered, fqdn, apexes}}` rather than writing a
  route-less entry.

  ## Cert reporting only

  Certificate provisioning is a separate lane (gge.12.4, `Mjolnir.Gateway.Certs`).
  This module never provisions — it only *reports* `cert_present` by checking
  whether a cert file for the fqdn exists.

  ## The ops seam (macOS-testable)

  Registry, reconcile, apex, VM-liveness, IP-resolution, and cert-check effects
  all go through an injectable `ops` map; tests pass a fake registry + fake
  reconcile so the merge/validate/reconcile behaviour is verified without a live
  server.
  """

  require Logger

  alias Mjolnir.Deploy.Registry
  alias Mjolnir.Gateway.Routes

  @default_certs_dir "/etc/mjolnir/certs"

  @typedoc "Injectable effect seam; defaults capture the real modules."
  @type ops :: %{
          registry_get: (String.t() -> {:ok, Registry.Entry.t()} | {:error, :not_found}),
          registry_put: (String.t(), map() -> {:ok, Registry.Entry.t()} | {:error, term()}),
          registry_list: (-> [Registry.Entry.t()]),
          reconcile: (-> any()),
          apexes: (-> [String.t()]),
          running_vm_ids: (-> [String.t()] | MapSet.t()),
          ip_resolver: (String.t() -> String.t()),
          cert_present: (String.t() -> boolean())
        }

  @doc """
  Set (or change) an app's custom domain.

  Reads the current registry entry, validates the fqdn's apex is configured,
  merges `custom_domain: fqdn` in, writes the full attr set back, and triggers a
  gateway reconcile.

  Returns:
    - `{:ok, %{app, fqdn, backend, apex_registered: true, cert_present}}`
    - `{:error, :not_found}` — no deployed app by that name
    - `{:error, {:apex_not_registered, fqdn, apexes}}` — fqdn matches no apex
    - `{:error, {:registry_failed, reason}}`
  """
  @spec set_domain(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def set_domain(app_name, fqdn, opts \\ []) when is_binary(app_name) and is_binary(fqdn) do
    ops = merged_ops(opts)
    apexes = ops.apexes.()

    with {:ok, entry} <- ops.registry_get.(app_name),
         {:ok, {_sub, _apex}} <- validate_apex(fqdn, apexes),
         {:ok, updated} <-
           ops.registry_put.(app_name, merge_attrs(entry, %{custom_domain: fqdn})) do
      ops.reconcile.()

      {:ok,
       %{
         app: app_name,
         fqdn: fqdn,
         backend: backend(updated, ops),
         apex_registered: true,
         cert_present: ops.cert_present.(fqdn)
       }}
    else
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :no_apex} ->
        {:error, {:apex_not_registered, fqdn, apexes}}

      {:error, reason} ->
        {:error, {:registry_failed, reason}}
    end
  end

  @doc """
  Clear an app's custom domain (merge-aware) and reconcile.

  Returns `{:ok, %{app, removed: true}}` or `{:error, :not_found}`.
  """
  @spec remove_domain(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def remove_domain(app_name, opts \\ []) when is_binary(app_name) do
    ops = merged_ops(opts)

    with {:ok, entry} <- ops.registry_get.(app_name),
         {:ok, _updated} <-
           ops.registry_put.(app_name, merge_attrs(entry, %{custom_domain: nil})) do
      ops.reconcile.()
      {:ok, %{app: app_name, removed: true}}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, {:registry_failed, reason}}
    end
  end

  @doc """
  List all deployed apps joined with their live gateway backend.

  Each entry is `%{app_name, url, custom_domain, service_vm_id, backend, port}`
  where `backend` is `"<guest_ip>:<port>"` when the app's service VM is currently
  running/local (and a port is known), else `nil`.
  """
  @spec list_apps(keyword()) :: [map()]
  def list_apps(opts \\ []) do
    ops = merged_ops(opts)
    running = running_set(ops.running_vm_ids.())

    for entry <- ops.registry_list.() do
      %{
        app_name: entry.app_name,
        url: entry.url,
        custom_domain: entry.custom_domain,
        service_vm_id: entry.service_vm_id,
        port: entry.port,
        backend: live_backend(entry, running, ops)
      }
    end
  end

  # --- internals -------------------------------------------------------------

  defp validate_apex(fqdn, apexes) do
    case Routes.split_fqdn(fqdn, apexes) do
      {:ok, _} = ok -> ok
      {:error, :no_apex} = err -> err
    end
  end

  # Rebuild the full settable attr set from the current entry, then apply the
  # override. Every Registry.Entry field the reconciler/route generator relies on
  # must be re-supplied or Registry.put wipes it.
  defp merge_attrs(%Registry.Entry{} = e, override) do
    %{
      release_snapshot: e.release_snapshot,
      service_vm_id: e.service_vm_id,
      url: e.url,
      port: e.port,
      custom_domain: e.custom_domain
    }
    |> Map.merge(override)
  end

  # Backend for the just-written entry (used in the set_domain response). Unlike
  # list_apps this does not gate on VM liveness — the caller just set the domain
  # and wants to see the intended backend.
  defp backend(%Registry.Entry{service_vm_id: vm_id, port: port}, ops)
       when is_binary(vm_id) and is_integer(port) do
    "#{ops.ip_resolver.(vm_id)}:#{port}"
  end

  defp backend(_entry, _ops), do: nil

  defp live_backend(%Registry.Entry{service_vm_id: vm_id, port: port}, running, ops)
       when is_binary(vm_id) and is_integer(port) do
    if MapSet.member?(running, vm_id), do: "#{ops.ip_resolver.(vm_id)}:#{port}", else: nil
  end

  defp live_backend(_entry, _running, _ops), do: nil

  defp running_set(%MapSet{} = set), do: set
  defp running_set(list) when is_list(list), do: MapSet.new(list)

  defp merged_ops(opts), do: Map.merge(default_ops(), Map.new(Keyword.get(opts, :ops, [])))

  defp default_ops do
    %{
      registry_get: &Registry.get/1,
      registry_put: &Registry.put/2,
      registry_list: &Registry.list/0,
      reconcile: &Mjolnir.Gateway.RouteReconciler.trigger/0,
      apexes: &configured_apexes/0,
      running_vm_ids: &default_running_vm_ids/0,
      ip_resolver: &Mjolnir.Network.allocate_ip/1,
      cert_present: &default_cert_present/1
    }
  end

  defp configured_apexes do
    Application.get_env(:mjolnir, :gateway_apexes, [
      "vm.worldtree.network",
      "worldtree.network",
      "identikey.io"
    ])
  end

  defp default_running_vm_ids do
    Mjolnir.VM.list()
    |> Enum.filter(&(Map.get(&1, :state) == :running))
    |> Enum.map(& &1.id)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # TODO(gge.12.4): replace this file-existence probe with a
  # Mjolnir.Gateway.Certs.present?/1 (or /2) call once the cert lane lands. Until
  # then we only *report* whether a cert file for the fqdn is on disk; we never
  # provision one here.
  defp default_cert_present(fqdn) do
    dir = Application.get_env(:mjolnir, :gateway_certs_dir, @default_certs_dir)
    Enum.any?([fqdn <> ".crt", fqdn <> ".pem"], &File.exists?(Path.join(dir, &1)))
  end
end
