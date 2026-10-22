defmodule Mjolnir.API.Adopt do
  @moduledoc """
  Cutover-free registry adopt for an existing running VM.

  `mj deploy` always spawns a fresh service VM and stops the previous one.
  Stateful hives (B0 Buzz relay) cannot survive that. Adopt writes a
  `Deploy.Registry` row for a VM that already exists and MUST NOT spawn
  or stop anything.
  """

  require Logger

  alias Mjolnir.Deploy.Registry
  alias Mjolnir.Gateway.RouteReconciler

  @typedoc "Injectable effect seam."
  @type ops :: %{
          registry_get: (String.t() -> {:ok, Registry.Entry.t()} | {:error, :not_found}),
          registry_put: (String.t(), map() -> {:ok, Registry.Entry.t()} | {:error, term()}),
          vm_get: (String.t() -> {:ok, map()} | {:error, term()}),
          snapshot: (String.t(), String.t() -> {:ok, map()} | {:error, term()}),
          reconcile: (-> any())
        }

  @doc """
  Adopt `vm_id` as app `app_name` on `port`.

  Returns `{:ok, entry}` or
    - `{:error, :vm_not_found}`
    - `{:error, :app_exists}` — a non-stateful app already occupies the name
    - `{:error, :stateful_vm_mismatch}` — stateful app bound to a different VM
    - `{:error, {:snapshot_failed, reason}}`
    - `{:error, {:registry_failed, reason}}`
  """
  @spec adopt(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, Registry.Entry.t()} | {:error, term()}
  def adopt(app_name, vm_id, port, opts \\ [])
      when is_binary(app_name) and is_binary(vm_id) and is_integer(port) and port > 0 do
    ops = merged_ops(opts)
    owner_id = Keyword.get(opts, :owner_id)
    snap_name = Keyword.get(opts, :release_snapshot)
    force? = Keyword.get(opts, :force, false) == true

    with {:ok, _vm} <- fetch_vm(ops, vm_id),
         :ok <- conflict(ops, app_name, vm_id, force?),
         {:ok, release_snapshot} <- ensure_snapshot(ops, vm_id, app_name, snap_name) do
      prev =
        case ops.registry_get.(app_name) do
          {:ok, e} -> e
          _ -> nil
        end

      attrs = %{
        release_snapshot: release_snapshot,
        service_vm_id: vm_id,
        port: port,
        owner_id: owner_id || (prev && prev.owner_id),
        custom_domain: prev && prev.custom_domain,
        url: prev && prev.url,
        stateful: true
      }

      case ops.registry_put.(app_name, attrs) do
        {:ok, entry} ->
          ops.reconcile.()
          {:ok, entry}

        {:error, reason} ->
          {:error, {:registry_failed, reason}}
      end
    end
  end

  defp fetch_vm(ops, vm_id) do
    case ops.vm_get.(vm_id) do
      {:ok, vm} -> {:ok, vm}
      {:error, :not_found} -> {:error, :vm_not_found}
      {:error, :unreachable} -> {:error, :vm_not_found}
      {:error, _} -> {:error, :vm_not_found}
    end
  end

  defp conflict(ops, app_name, vm_id, force?) do
    case ops.registry_get.(app_name) do
      {:error, :not_found} ->
        :ok

      {:ok, %{stateful: true, service_vm_id: ^vm_id}} ->
        :ok

      {:ok, %{stateful: true}} when force? ->
        :ok

      {:ok, %{stateful: true}} ->
        {:error, :stateful_vm_mismatch}

      {:ok, _entry} when force? ->
        :ok

      {:ok, _entry} ->
        {:error, :app_exists}
    end
  end

  defp ensure_snapshot(_ops, _vm_id, _app, name) when is_binary(name) and name != "",
    do: {:ok, name}

  defp ensure_snapshot(ops, vm_id, app_name, _) do
    name = "adopt-#{safe_slug(app_name)}-#{System.os_time(:second)}"

    case ops.snapshot.(vm_id, name) do
      {:ok, _} -> {:ok, name}
      {:error, reason} -> {:error, {:snapshot_failed, reason}}
    end
  end

  defp safe_slug(app_name) do
    app_name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "_")
  end

  defp merged_ops(opts), do: Map.merge(default_ops(), Map.new(Keyword.get(opts, :ops, [])))

  defp default_ops do
    %{
      registry_get: &Registry.get/1,
      registry_put: &Registry.put/2,
      vm_get: &Mjolnir.VM.get/1,
      snapshot: fn vm_id, name -> Mjolnir.VM.snapshot(vm_id, name) end,
      reconcile: fn -> RouteReconciler.trigger() end
    }
  end
end
