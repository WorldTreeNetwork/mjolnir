defmodule Mjolnir.BTRFS do
  @moduledoc """
  BTRFS operations for VM filesystem management.

  Provides copy-on-write cloning, snapshotting, and filesystem operations
  for instant VM creation and checkpoint management.

  Storage layout:
    @base/           — template BTRFS subvolumes (e.g., ubuntu-24.04/)
    @vms/{vm_id}/    — per-VM rootfs subvolume snapshots
    @snapshots/{name}/ — named snapshot subvolumes + JSON metadata
  """

  require Logger

  # Defense-in-depth: reject names that could escape the intended directory.
  # The router validates too, but this protects against internal callers.
  @safe_name_regex ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/

  defp validate_path_component!(name, label) do
    unless is_binary(name) and Regex.match?(@safe_name_regex, name) and
             not String.contains?(name, "..") and byte_size(name) <= 128 do
      raise ArgumentError, "#{label} contains unsafe characters: #{inspect(name)}"
    end

    name
  end

  @doc """
  Clone a base image to create a new VM rootfs.

  Uses `btrfs subvolume snapshot` for instant CoW clone on BTRFS.
  The base image should be a BTRFS subvolume stored in @base/.
  """
  def clone(base_image, vm_id) do
    validate_path_component!(base_image, "base_image")
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    vm_subdir = Application.get_env(:mjolnir, :vm_storage_subdir, "@vms")
    source = Path.join([btrfs_root, "@base", base_image])
    dest = Path.join([btrfs_root, vm_subdir, vm_id])

    with :ok <- ensure_dir(Path.join([btrfs_root, vm_subdir])),
         :ok <- snapshot_subvolume(source, dest) do
      {:ok, dest}
    end
  end

  @doc """
  Clone a named snapshot to create a new VM rootfs.

  Uses `btrfs subvolume snapshot` from @snapshots/{name}/ → @vms/{vm_id}/.
  """
  def clone_from_snapshot(name, vm_id) do
    validate_path_component!(name, "snapshot name")
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    vm_subdir = Application.get_env(:mjolnir, :vm_storage_subdir, "@vms")
    source = Path.join([btrfs_root, "@snapshots", name])
    dest = Path.join([btrfs_root, vm_subdir, vm_id])

    if File.dir?(source) do
      with :ok <- ensure_dir(Path.join([btrfs_root, vm_subdir])),
           :ok <- snapshot_subvolume(source, dest) do
        {:ok, dest}
      end
    else
      {:error, {:snapshot_not_found, name}}
    end
  end

  @doc """
  Create a named snapshot of a VM's rootfs.

  Uses `btrfs subvolume snapshot` from @vms/{vm_id}/ → @snapshots/{name}/
  and writes a JSON metadata sidecar file.

  ## Options
    - `:source_vm_id` — recorded in metadata (defaults to vm_id)
    - `:owner_id` — owner identity for multi-tenancy
  """
  def create_snapshot(vm_id, name, opts \\ []) do
    validate_path_component!(name, "snapshot name")
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    vm_subdir = Application.get_env(:mjolnir, :vm_storage_subdir, "@vms")
    source = Path.join([btrfs_root, vm_subdir, vm_id])
    snapshot_dir = Path.join([btrfs_root, "@snapshots"])
    dest = Path.join(snapshot_dir, name)
    meta_path = Path.join(snapshot_dir, "#{name}.json")

    if File.dir?(dest) do
      {:error, {:snapshot_exists, name}}
    else
      with :ok <- ensure_dir(snapshot_dir),
           :ok <- snapshot_subvolume(source, dest) do
        size_bytes =
          case System.cmd("du", ["-sb", dest], stderr_to_stdout: true) do
            {output, 0} -> output |> String.split("\t") |> List.first() |> String.to_integer()
            _ -> 0
          end

        metadata = %{
          name: name,
          source_vm_id: opts[:source_vm_id] || vm_id,
          owner_id: opts[:owner_id],
          created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          size_bytes: size_bytes
        }

        File.write!(meta_path, Jason.encode!(metadata, pretty: true))
        Logger.info("Created snapshot '#{name}' from VM #{vm_id}")
        {:ok, metadata}
      end
    end
  end

  @doc """
  List all snapshots with their metadata.

  Reads @snapshots/*.json files and returns a list of metadata maps.
  """
  def list_snapshots do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    snapshot_dir = Path.join([btrfs_root, "@snapshots"])

    case File.ls(snapshot_dir) do
      {:ok, files} ->
        snapshots =
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(fn json_file ->
            path = Path.join(snapshot_dir, json_file)

            case File.read(path) do
              {:ok, content} ->
                case Jason.decode(content) do
                  {:ok, meta} -> atomize_metadata(meta)
                  _ -> nil
                end

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, snapshots}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:list_snapshots_failed, reason}}
    end
  end

  @doc """
  Get a single snapshot's metadata and directory path.

  Returns `{:ok, %{metadata: map, path: string}}` or `{:error, reason}`.
  """
  def get_snapshot(name) do
    validate_path_component!(name, "snapshot name")
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    snapshot_dir = Path.join([btrfs_root, "@snapshots"])
    meta_path = Path.join(snapshot_dir, "#{name}.json")
    subvol_path = Path.join(snapshot_dir, name)

    with {:ok, content} <- File.read(meta_path),
         {:ok, metadata} <- Jason.decode(content) do
      {:ok, %{metadata: atomize_metadata(metadata), path: subvol_path}}
    else
      {:error, :enoent} -> {:error, {:snapshot_not_found, name}}
      {:error, reason} -> {:error, {:read_snapshot_failed, reason}}
    end
  end

  @doc """
  Delete a snapshot (both subvolume directory and .json metadata file).
  """
  def delete_snapshot(name) do
    validate_path_component!(name, "snapshot name")
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    snapshot_dir = Path.join([btrfs_root, "@snapshots"])
    subvol_path = Path.join(snapshot_dir, name)
    meta_path = Path.join(snapshot_dir, "#{name}.json")

    if File.dir?(subvol_path) or File.exists?(meta_path) do
      _ = delete_subvolume(subvol_path)
      _ = File.rm(meta_path)
      Logger.info("Deleted snapshot '#{name}'")
      :ok
    else
      {:error, {:snapshot_not_found, name}}
    end
  end

  @doc """
  Delete the iroh key from a rootfs directory to force new key generation.

  This is needed when spawning a VM from a snapshot to ensure each VM gets
  a unique iroh node ID and ticket, rather than sharing the same network
  identity as the snapshot source.

  Directly removes /etc/mjolnir/iroh.key from the rootfs directory (no mount needed
  since the rootfs is now a BTRFS subvolume directory).
  """
  def delete_iroh_key(rootfs_dir) do
    key_path = Path.join(rootfs_dir, "etc/mjolnir/iroh.key")

    if File.exists?(key_path) do
      File.rm!(key_path)
      Logger.debug("Deleted iroh key from rootfs: #{rootfs_dir}")
    end

    :ok
  rescue
    e ->
      Logger.warning("Failed to delete iroh key: #{inspect(e)}")
      {:error, {:delete_iroh_key_failed, e}}
  end

  @doc """
  Delete a subvolume (VM overlay or snapshot).

  This is the irreversible primitive. Prefer `trash_subvolume/2` for any VM
  rootfs so a deletion can be undone — the only caller of `delete_subvolume`
  on a live VM rootfs should be the trash reaper (`reap_trash/1`).
  """
  def delete_subvolume(path) do
    case System.cmd("sudo", ["-n", "btrfs", "subvolume", "delete", path], stderr_to_stdout: true) do
      {_, 0} ->
        Logger.debug("Deleted BTRFS subvolume: #{path}")
        :ok

      {output, code} ->
        Logger.error("Failed to delete subvolume #{path}: #{output}")
        {:error, {:btrfs_delete_failed, code, output}}
    end
  end

  @doc """
  The `@trash` directory holding soft-deleted subvolumes awaiting GC.
  """
  def trash_root do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    Path.join(btrfs_root, "@trash")
  end

  @doc """
  Soft-delete a VM rootfs subvolume by moving it into `@trash/<name>__<ts>__<rand>/`.

  This is the durability-critical alternative to `delete_subvolume/1`: a
  rename within the same BTRFS filesystem is O(1) and fully reversible via
  `restore_trashed/2`, so no inline teardown path can ever cause permanent
  data loss. The trash is reclaimed later by `reap_trash/1`.

  Returns `{:ok, trash_path}` on success, `:ok` if the source is already gone
  (idempotent), or `{:error, reason}` if the move failed — in which case the
  subvolume is intentionally LEFT IN PLACE rather than hard-deleted, so it
  remains recoverable.
  """
  def trash_subvolume(path, opts \\ []) do
    cond do
      is_nil(path) ->
        :ok

      not File.exists?(path) ->
        :ok

      true ->
        trash_dir = Keyword.get(opts, :trash_root, trash_root())
        basename = Path.basename(path)
        # Second-resolution timestamp + short random suffix guarantees a unique
        # destination even if the same VM id is trashed twice in one second.
        stamp = System.os_time(:second)
        rand = :rand.uniform(0xFFFF) |> Integer.to_string(16)
        dest = Path.join(trash_dir, "#{basename}__#{stamp}__#{rand}")

        with :ok <- ensure_dir(trash_dir),
             {_, 0} <- System.cmd("mv", [path, dest], stderr_to_stdout: true) do
          Logger.info("Soft-deleted subvolume #{path} -> #{dest}")
          # Optional metadata sidecar (e.g. the VM's spawn_config) so a later
          # `restore_trashed/2` can re-persist enough state for Reconcile to
          # resume the restored VM. Best-effort: a failed sidecar write never
          # fails the trash itself.
          case Keyword.get(opts, :metadata) do
            nil -> :ok
            meta -> _ = write_trash_metadata(dest, meta)
          end

          {:ok, dest}
        else
          {output, code} when is_binary(output) and is_integer(code) ->
            Logger.error(
              "Failed to trash subvolume #{path} (code #{code}): #{output}. " <>
                "Leaving in place — recover manually or let Cleanup retry."
            )

            {:error, {:btrfs_trash_failed, code, output}}

          {:error, reason} ->
            Logger.error("Failed to trash subvolume #{path}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  @doc """
  Restore a previously trashed subvolume to `dest` (e.g. on a failed `nuke`).

  If `dest` already exists (a partial respawn left a stale subvolume), it is
  itself trashed first so the restore lands cleanly. Returns `:ok` or
  `{:error, reason}`.
  """
  def restore_trashed(trash_path, dest) do
    cond do
      is_nil(trash_path) or not File.exists?(trash_path) ->
        {:error, {:trash_missing, trash_path}}

      true ->
        # Get the stale dest out of the way (recoverably) before restoring.
        _ = if File.exists?(dest), do: trash_subvolume(dest), else: :ok

        with :ok <- ensure_dir(Path.dirname(dest)),
             {_, 0} <- System.cmd("mv", [trash_path, dest], stderr_to_stdout: true) do
          Logger.warning("Restored trashed subvolume #{trash_path} -> #{dest}")
          :ok
        else
          {output, code} when is_binary(output) ->
            {:error, {:btrfs_restore_failed, code, output}}

          other ->
            {:error, other}
        end
    end
  end

  @doc """
  Hard-delete trashed subvolumes older than the retention window.

  Retention comes from `:trash_retention_seconds` (default 7 days). Returns
  `{:ok, reaped_count}`. Entries that fail to parse a timestamp are kept
  (fail-safe) so a malformed name never triggers premature deletion.
  """
  def reap_trash(opts \\ []) do
    trash_dir = Keyword.get(opts, :trash_root, trash_root())

    retention =
      Keyword.get(
        opts,
        :retention_seconds,
        Application.get_env(:mjolnir, :trash_retention_seconds, 7 * 24 * 60 * 60)
      )

    now = System.os_time(:second)

    case File.ls(trash_dir) do
      {:ok, entries} ->
        reaped =
          entries
          # Skip sidecar metadata files; they're reaped alongside their dir.
          |> Enum.reject(&String.ends_with?(&1, ".meta.json"))
          |> Enum.filter(fn entry -> reapable?(entry, now, retention) end)
          |> Enum.reduce(0, fn entry, acc ->
            path = Path.join(trash_dir, entry)
            _ = File.rm(meta_sidecar_path(path))

            case delete_subvolume(path) do
              :ok ->
                acc + 1

              {:error, _} ->
                # Fall back to a plain recursive remove (handles non-subvolume
                # leftovers); never block the reaper on one bad entry.
                _ = File.rm_rf(path)
                acc + 1
            end
          end)

        if reaped > 0, do: Logger.info("Reaped #{reaped} trashed subvolume(s)")
        {:ok, reaped}

      {:error, :enoent} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List soft-deleted subvolumes in `@trash`, newest first.

  Each entry: `%{vm_id, trashed_at (unix), age_seconds, reaps_in_seconds,
  path, metadata}`. `reaps_in_seconds` is relative to `:trash_retention_seconds`
  and clamps at 0 (already eligible for the next reap). Unparseable names are
  skipped. Pure filesystem read — no btrfs shell-out — so it is cheap.
  """
  def list_trash(opts \\ []) do
    trash_dir = Keyword.get(opts, :trash_root, trash_root())

    retention =
      Keyword.get(
        opts,
        :retention_seconds,
        Application.get_env(:mjolnir, :trash_retention_seconds, 7 * 24 * 60 * 60)
      )

    now = System.os_time(:second)

    case File.ls(trash_dir) do
      {:ok, entries} ->
        list =
          entries
          |> Enum.reject(&String.ends_with?(&1, ".meta.json"))
          |> Enum.flat_map(fn entry ->
            case String.split(entry, "__") do
              [vm_id, ts_str, _rand] ->
                case Integer.parse(ts_str) do
                  {ts, ""} ->
                    path = Path.join(trash_dir, entry)

                    [
                      %{
                        vm_id: vm_id,
                        trashed_at: ts,
                        age_seconds: max(now - ts, 0),
                        reaps_in_seconds: max(retention - (now - ts), 0),
                        path: path,
                        metadata: read_trash_metadata(path)
                      }
                    ]

                  _ ->
                    []
                end

              _ ->
                []
            end
          end)
          |> Enum.sort_by(& &1.trashed_at, :desc)

        {:ok, list}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Find the newest trashed subvolume for `vm_id` and return its entry (same
  shape as `list_trash/0` items), or `{:error, :not_found}`.
  """
  def find_trashed(vm_id, opts \\ []) do
    with {:ok, list} <- list_trash(opts) do
      case Enum.find(list, &(&1.vm_id == vm_id)) do
        nil -> {:error, :not_found}
        entry -> {:ok, entry}
      end
    end
  end

  @doc "Read a trash entry's metadata sidecar, or nil if absent/unreadable."
  def read_trash_metadata(trash_path) do
    with {:ok, content} <- File.read(meta_sidecar_path(trash_path)),
         {:ok, meta} <- Jason.decode(content) do
      meta
    else
      _ -> nil
    end
  end

  defp meta_sidecar_path(trash_path), do: trash_path <> ".meta.json"

  defp write_trash_metadata(trash_path, meta) do
    File.write(meta_sidecar_path(trash_path), Jason.encode!(meta, pretty: true))
  rescue
    e ->
      Logger.warning("Failed to write trash metadata for #{trash_path}: #{inspect(e)}")
      :error
  end

  @doc """
  Overall filesystem usage for the btrfs root, via `df`. Returns
  `%{total_bytes, used_bytes, free_bytes}` or `{:error, reason}`.
  """
  def disk_usage(root \\ nil) do
    path = root || Application.get_env(:mjolnir, :btrfs_root)

    case System.cmd("df", ["--block-size=1", "--output=size,used,avail", path],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        # Two lines: header, then "<size> <used> <avail>".
        case output |> String.split("\n", trim: true) |> List.last() |> String.split() do
          [size, used, avail | _] ->
            {:ok,
             %{
               total_bytes: String.to_integer(size),
               used_bytes: String.to_integer(used),
               free_bytes: String.to_integer(avail)
             }}

          _ ->
            {:error, {:df_parse_failed, output}}
        end

      {output, code} ->
        {:error, {:df_failed, code, output}}
    end
  end

  @doc """
  CoW-aware usage for a path (a subvolume or a dir of subvolumes) via
  `btrfs filesystem du -s`. Returns `%{total_bytes, exclusive_bytes}`.

  `total_bytes` is logical (counts shared blocks); `exclusive_bytes` is the
  data unique to this path — the real marginal cost. Both are pre-compression.
  """
  def du_usage(path) do
    case System.cmd("btrfs", ["filesystem", "du", "-s", "--bytes", path], stderr_to_stdout: true) do
      {output, 0} ->
        # Header line + data line: "<total> <exclusive> <shared> <path>".
        case output |> String.split("\n", trim: true) |> List.last() |> String.split() do
          [total, exclusive | _] ->
            {:ok,
             %{
               total_bytes: parse_int(total),
               exclusive_bytes: parse_int(exclusive)
             }}

          _ ->
            {:error, {:du_parse_failed, output}}
        end

      {output, code} ->
        {:error, {:du_failed, code, output}}
    end
  end

  @doc "Exclusive bytes for a single subvolume, or nil if it can't be measured."
  def du_exclusive(path) do
    case du_usage(path) do
      {:ok, %{exclusive_bytes: b}} -> b
      _ -> nil
    end
  end

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> 0
    end
  end

  # Trash entries are named "<name>__<unix_ts>__<rand>". Reap only when the
  # parsed timestamp is older than the retention window. Unparseable names are
  # KEPT (returns false) — fail-safe against deleting something we can't date.
  defp reapable?(entry, now, retention) do
    case String.split(entry, "__") do
      [_name, ts_str, _rand] ->
        case Integer.parse(ts_str) do
          {ts, ""} -> now - ts > retention
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc """
  Check if a path is a BTRFS subvolume.
  """
  def subvolume?(path) do
    case System.cmd("sudo", ["-n", "btrfs", "subvolume", "show", path], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  @doc """
  List subvolumes under a path.
  """
  def list_subvolumes(path) do
    case System.cmd("sudo", ["-n", "btrfs", "subvolume", "list", path], stderr_to_stdout: true) do
      {output, 0} ->
        subvols =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_subvolume_line/1)
          |> Enum.reject(&is_nil/1)

        {:ok, subvols}

      {output, code} ->
        {:error, {:btrfs_list_failed, code, output}}
    end
  end

  # Private helpers

  # Known metadata keys — safe to atomize since we control the schema
  @metadata_keys ~w(name source_vm_id owner_id created_at size_bytes)

  defp atomize_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn
      {k, v} when is_binary(k) and k in @metadata_keys -> {String.to_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp snapshot_subvolume(source, dest) do
    case System.cmd("sudo", ["-n", "btrfs", "subvolume", "snapshot", source, dest],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        Logger.debug("Created BTRFS snapshot: #{source} -> #{dest}")
        :ok

      {output, code} ->
        Logger.error("BTRFS snapshot failed: #{output}")
        {:error, {:btrfs_snapshot_failed, code, output}}
    end
  end

  defp ensure_dir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  defp parse_subvolume_line(line) do
    # Format: "ID 256 gen 123 top level 5 path @base/ubuntu-24.04"
    case Regex.run(~r/path (.+)$/, line) do
      [_, path] -> path
      _ -> nil
    end
  end
end
