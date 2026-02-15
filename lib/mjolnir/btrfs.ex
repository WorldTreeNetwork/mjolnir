defmodule Mjolnir.BTRFS do
  @moduledoc """
  BTRFS operations for VM filesystem management.

  Provides copy-on-write cloning, snapshotting, and filesystem operations
  for instant VM creation and checkpoint management.

  Storage layout:
    @base/           — template ext4 images (e.g., ubuntu-24.04.ext4)
    @vms/{vm_id}/    — per-VM rootfs clones
    @snapshots/      — named snapshots (ext4 + JSON metadata)
  """

  require Logger

  @doc """
  Clone a base image to create a new VM rootfs.

  Uses cp --reflink for instant CoW clone on BTRFS.
  The base image should be an ext4 file stored on the BTRFS filesystem.
  """
  def clone(base_image, vm_id) do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    vm_subdir = Application.get_env(:mjolnir, :vm_storage_subdir, "@vms")
    # Base image is an ext4 file, e.g., @base/ubuntu-24.04.ext4
    source = Path.join([btrfs_root, "@base", "#{base_image}.ext4"])
    dest_dir = Path.join([btrfs_root, vm_subdir, vm_id])
    dest = Path.join(dest_dir, "rootfs.ext4")

    with :ok <- ensure_dir(dest_dir),
         :ok <- reflink_copy(source, dest) do
      {:ok, dest}
    end
  end

  @doc """
  Clone a named snapshot to create a new VM rootfs.

  Uses reflink copy from @snapshots/{name}.ext4 → @vms/{vm_id}/rootfs.ext4.
  """
  def clone_from_snapshot(name, vm_id) do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    vm_subdir = Application.get_env(:mjolnir, :vm_storage_subdir, "@vms")
    source = Path.join([btrfs_root, "@snapshots", "#{name}.ext4"])
    dest_dir = Path.join([btrfs_root, vm_subdir, vm_id])
    dest = Path.join(dest_dir, "rootfs.ext4")

    if File.exists?(source) do
      with :ok <- ensure_dir(dest_dir),
           :ok <- reflink_copy(source, dest) do
        {:ok, dest}
      end
    else
      {:error, {:snapshot_not_found, name}}
    end
  end

  @doc """
  Resize a rootfs ext4 image to the given size in MB.

  Uses truncate to grow the sparse file, then resize2fs to expand the filesystem.
  Only grows — will not shrink an image.
  """
  def resize_rootfs(rootfs_path, size_mb) do
    with {_, 0} <-
           System.cmd("truncate", ["-s", "#{size_mb}M", rootfs_path], stderr_to_stdout: true),
         {_, 0} <- System.cmd("resize2fs", [rootfs_path], stderr_to_stdout: true) do
      Logger.debug("Resized rootfs to #{size_mb}MB: #{rootfs_path}")
      :ok
    else
      {output, code} ->
        Logger.error("Rootfs resize failed: #{output}")
        {:error, {:resize_failed, code, output}}
    end
  end

  @doc """
  Create a named snapshot of a VM's rootfs.

  Reflink copies @vms/{vm_id}/rootfs.ext4 → @snapshots/{name}.ext4
  and writes a JSON metadata sidecar file.

  ## Options
    - `:source_vm_id` — recorded in metadata (defaults to vm_id)
  """
  def create_snapshot(vm_id, name, opts \\ []) do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    vm_subdir = Application.get_env(:mjolnir, :vm_storage_subdir, "@vms")
    source = Path.join([btrfs_root, vm_subdir, vm_id, "rootfs.ext4"])
    snapshot_dir = Path.join([btrfs_root, "@snapshots"])
    dest = Path.join(snapshot_dir, "#{name}.ext4")
    meta_path = Path.join(snapshot_dir, "#{name}.json")

    if File.exists?(dest) do
      {:error, {:snapshot_exists, name}}
    else
      with :ok <- ensure_dir(snapshot_dir),
           :ok <- reflink_copy(source, dest) do
        size_bytes =
          case File.stat(dest) do
            {:ok, %{size: size}} -> size
            _ -> 0
          end

        metadata = %{
          name: name,
          source_vm_id: opts[:source_vm_id] || vm_id,
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
                  {:ok, meta} -> meta
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
  Get a single snapshot's metadata and file path.

  Returns `{:ok, %{metadata: map, path: string}}` or `{:error, reason}`.
  """
  def get_snapshot(name) do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    snapshot_dir = Path.join([btrfs_root, "@snapshots"])
    meta_path = Path.join(snapshot_dir, "#{name}.json")
    ext4_path = Path.join(snapshot_dir, "#{name}.ext4")

    with {:ok, content} <- File.read(meta_path),
         {:ok, metadata} <- Jason.decode(content) do
      {:ok, %{metadata: metadata, path: ext4_path}}
    else
      {:error, :enoent} -> {:error, {:snapshot_not_found, name}}
      {:error, reason} -> {:error, {:read_snapshot_failed, reason}}
    end
  end

  @doc """
  Delete a snapshot (both .ext4 and .json files).
  """
  def delete_snapshot(name) do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    snapshot_dir = Path.join([btrfs_root, "@snapshots"])
    ext4_path = Path.join(snapshot_dir, "#{name}.ext4")
    meta_path = Path.join(snapshot_dir, "#{name}.json")

    if File.exists?(ext4_path) or File.exists?(meta_path) do
      _ = File.rm(ext4_path)
      _ = File.rm(meta_path)
      Logger.info("Deleted snapshot '#{name}'")
      :ok
    else
      {:error, {:snapshot_not_found, name}}
    end
  end

  @doc """
  Re-sparsify a rootfs image by punching holes where zeros exist.

  Run this after `fstrim` inside the guest to reclaim freed blocks on the host.
  Uses `fallocate --dig-holes` which is a Linux-only operation.
  """
  def compact_rootfs(rootfs_path) do
    case System.cmd("fallocate", ["--dig-holes", rootfs_path], stderr_to_stdout: true) do
      {_, 0} ->
        Logger.debug("Compacted rootfs: #{rootfs_path}")
        :ok

      {output, code} ->
        Logger.error("Rootfs compaction failed: #{output}")
        {:error, {:compact_failed, code, output}}
    end
  end

  @doc """
  Delete the iroh key from a rootfs image to force new key generation.

  This is needed when spawning a VM from a snapshot to ensure each VM gets
  a unique iroh node ID and ticket, rather than sharing the same network
  identity as the snapshot source.

  Mounts the ext4 image, deletes /etc/mjolnir/iroh.key if present, unmounts.
  """
  def delete_iroh_key(rootfs_path) do
    mount_point =
      Path.join(System.tmp_dir!(), "mjolnir-mount-#{:erlang.unique_integer([:positive])}")

    with :ok <- ensure_dir(mount_point),
         {_, 0} <-
           System.cmd("mount", ["-o", "loop", rootfs_path, mount_point], stderr_to_stdout: true) do
      # Delete iroh key if it exists
      key_path = Path.join(mount_point, "etc/mjolnir/iroh.key")

      if File.exists?(key_path) do
        File.rm!(key_path)
        Logger.debug("Deleted iroh key from rootfs: #{rootfs_path}")
      end

      # Unmount
      case System.cmd("umount", [mount_point], stderr_to_stdout: true) do
        {_, 0} ->
          File.rmdir(mount_point)
          :ok

        {output, code} ->
          Logger.error("Failed to unmount #{mount_point}: #{output}")
          {:error, {:unmount_failed, code, output}}
      end
    else
      {:error, reason} ->
        # ensure_dir failed
        {:error, reason}

      {output, code} ->
        # mount failed
        _ = File.rmdir(mount_point)
        Logger.error("Failed to mount rootfs for key deletion: #{output}")
        {:error, {:mount_failed, code, output}}
    end
  end

  @doc """
  Delete a subvolume (VM overlay or snapshot).
  """
  def delete_subvolume(path) do
    case System.cmd("btrfs", ["subvolume", "delete", path], stderr_to_stdout: true) do
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
    case System.cmd("btrfs", ["subvolume", "show", path], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  @doc """
  List subvolumes under a path.
  """
  def list_subvolumes(path) do
    case System.cmd("btrfs", ["subvolume", "list", path], stderr_to_stdout: true) do
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

  defp reflink_copy(source, dest) do
    case System.cmd("cp", ["--reflink=auto", source, dest], stderr_to_stdout: true) do
      {_, 0} ->
        Logger.debug("Created reflink copy: #{source} -> #{dest}")
        :ok

      {output, code} ->
        Logger.error("Reflink copy failed: #{output}")
        {:error, {:reflink_copy_failed, code, output}}
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
