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
