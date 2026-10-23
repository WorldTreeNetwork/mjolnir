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

  Memory snapshots are directories named `@snapshots/<name>.mem` beside the
  read-only CoW subvolume, not subvolumes themselves. `memory_snapshots`
  counts them on their own. Compression of those files is the btrfs mount
  (`compress=zstd`), not a second pass in this module. `btrfs filesystem du`
  still sees them inside the `@snapshots` area when that command works; the
  separate object is so operators can read RAM-image cost without treating
  it as another CoW snapshot.
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

    %{disk: disk, areas: areas, memory_snapshots: memory_snapshots(btrfs_root)}
  end

  @doc """
  Count and size of `@snapshots/*.mem` directories.

  `logical_bytes` is the sum of file sizes (`st_size`). `exclusive_bytes` is
  `btrfs filesystem du` when that works, and otherwise the allocated blocks
  of those files. On a filesystem that reports no allocated blocks (tmpfs
  often does), exclusive falls back to the logical size: nothing is shared,
  so the marginal cost is the whole file. A missing snapshots directory is
  count 0.
  """
  @spec memory_snapshots(String.t() | nil) :: %{
          count: non_neg_integer(),
          logical_bytes: non_neg_integer(),
          exclusive_bytes: non_neg_integer()
        }
  def memory_snapshots(nil), do: %{count: 0, logical_bytes: 0, exclusive_bytes: 0}

  def memory_snapshots(btrfs_root) when is_binary(btrfs_root) do
    dirs = memory_dirs(Path.join(btrfs_root, "@snapshots"))

    Enum.reduce(dirs, %{count: 0, logical_bytes: 0, exclusive_bytes: 0}, fn dir, acc ->
      {logical, allocated} = tree_usage(dir)

      %{
        count: acc.count + 1,
        logical_bytes: acc.logical_bytes + logical,
        exclusive_bytes: acc.exclusive_bytes + exclusive_bytes(dir, logical, allocated)
      }
    end)
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
        |> Enum.reject(
          &(String.starts_with?(&1, ".") or String.ends_with?(&1, ".json") or
              String.ends_with?(&1, ".mem"))
        )
        |> length()

      _ ->
        0
    end
  end

  defp percent(_used, total) when total in [nil, 0], do: 0.0
  defp percent(used, total), do: Float.round(used / total * 100, 1)

  defp memory_dirs(snap) do
    case File.ls(snap) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".mem"))
        |> Enum.map(&Path.join(snap, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.sort()

      _ ->
        []
    end
  end

  # `{logical, allocated}`. Allocated is `st_blocks * 512`.
  defp tree_usage(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} ->
            Enum.reduce(names, {0, 0}, fn name, {logical, allocated} ->
              {l, a} = tree_usage(Path.join(path, name))
              {logical + l, allocated + a}
            end)

          _ ->
            {0, 0}
        end

      {:ok, %{type: :regular, size: size}} ->
        # Elixir 1.16 `File.Stat` has no block count. `stat -c %b` is the
        # allocated 512-byte units, without reading the RAM image into BEAM.
        allocated =
          case System.cmd("stat", ["-c", "%b", path], stderr_to_stdout: true) do
            {out, 0} ->
              case Integer.parse(String.trim(out)) do
                {blocks, ""} -> blocks * 512
                _ -> 0
              end

            _ ->
              0
          end

        {size, allocated}

      _ ->
        {0, 0}
    end
  end

  defp exclusive_bytes(dir, logical, allocated) do
    measured =
      try do
        BTRFS.du_usage(dir)
      rescue
        _ -> :unavailable
      end

    case measured do
      {:ok, %{exclusive_bytes: n}} when is_integer(n) -> n
      _ when allocated > 0 -> allocated
      _ -> logical
    end
  end
end
