defmodule Mjolnir.Storage do
  @moduledoc """
  User-facing storage reporting and trash recovery.

  Mjolnir stores every VM as a BTRFS subvolume under `btrfs_root`:

    - `@base/`      — shared template images (reflink source for clones)
    - `@vms/`       — live per-VM rootfs subvolumes
    - `@snapshots/` — named + dormant snapshots
    - `@trash/`     — soft-deleted subvolumes awaiting GC (see `Mjolnir.BTRFS`)

  Because clones are copy-on-write and the filesystem is zstd-compressed, the
  physically-consumed bytes (`disk`) are much smaller than the logical sum of
  per-VM sizes (`areas[].total_bytes`). `exclusive_bytes` is the marginal cost
  of an area — blocks not shared with anything else.
  """

  require Logger

  alias Mjolnir.BTRFS

  @areas ~w(@base @vms @snapshots @trash)

  @doc """
  A full storage overview: whole-disk usage, per-area CoW-aware sizes, and
  object counts. Shaped for the `/api/storage` endpoint and `mj storage`.
  """
  @spec overview() :: %{optional(atom()) => any()}
  def overview do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)

    disk =
      case BTRFS.disk_usage(btrfs_root) do
        {:ok, d} -> Map.put(d, :use_percent, percent(d.used_bytes, d.total_bytes))
        {:error, _} -> nil
      end

    areas =
      Enum.map(@areas, fn area ->
        path = Path.join(btrfs_root, area)

        usage =
          case BTRFS.du_usage(path) do
            {:ok, u} -> u
            {:error, _} -> %{total_bytes: nil, exclusive_bytes: nil}
          end

        Map.merge(%{name: area, count: count_entries(path)}, usage)
      end)

    %{disk: disk, areas: areas}
  end

  @doc """
  List soft-deleted VMs (delegates to `BTRFS.list_trash/0`), enriched with a
  human-friendly `restorable` flag (true when a metadata sidecar is present, so
  a restore can also re-persist the intent record).
  """
  @spec list_trash() :: {:ok, [map()]} | {:error, term()}
  def list_trash do
    with {:ok, entries} <- BTRFS.list_trash() do
      {:ok, Enum.map(entries, fn e -> Map.put(e, :restorable, e.metadata != nil) end)}
    end
  end

  @doc """
  Restore the most-recently trashed subvolume for `vm_id` back to `@vms/<id>`
  and, if a metadata sidecar is present, re-persist its `:running` record so
  `Mjolnir.Reconcile` resumes it (kicked immediately, not just on the 30s tick).

  Returns `{:ok, %{vm_id:, resumed:}}`. `resumed: false` means the subvolume
  was restored but no record could be reconstructed (the VM exists on disk but
  must be re-spawned manually).
  """
  @spec restore_from_trash(String.t()) :: {:ok, map()} | {:error, term()}
  def restore_from_trash(vm_id) when is_binary(vm_id) do
    dest = Mjolnir.Reconcile.rootfs_path(vm_id)

    cond do
      File.exists?(dest) ->
        {:error, :already_present}

      true ->
        with {:ok, entry} <- BTRFS.find_trashed(vm_id),
             :ok <- BTRFS.restore_trashed(entry.path, dest) do
          _ = File.rm(entry.path <> ".meta.json")
          resumed = maybe_repersist_record(entry.metadata)
          if resumed, do: kick_reconcile()
          {:ok, %{vm_id: vm_id, resumed: resumed}}
        end
    end
  end

  # --- internals ---

  defp maybe_repersist_record(nil), do: false

  defp maybe_repersist_record(metadata) do
    with {:ok, json} <- Jason.encode(metadata),
         {:ok, record} <- Mjolnir.StateStore.Record.from_json(json),
         :ok <- Mjolnir.StateStore.put(%{record | intent: :running}) do
      true
    else
      other ->
        Logger.warning("Trash restore: could not re-persist record: #{inspect(other)}")
        false
    end
  end

  defp kick_reconcile do
    Task.Supervisor.start_child(Mjolnir.TaskSupervisor, &Mjolnir.Reconcile.run/0)
  end

  defp count_entries(path) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(String.starts_with?(&1, ".") or String.ends_with?(&1, ".json")))
        |> length()

      _ ->
        0
    end
  end

  defp percent(_used, total) when total in [nil, 0], do: 0.0
  defp percent(used, total), do: Float.round(used / total * 100, 1)
end
