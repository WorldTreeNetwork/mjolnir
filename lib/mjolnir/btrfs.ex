defmodule Mjolnir.BTRFS do
  @moduledoc """
  BTRFS operations for VM filesystem management.

  Provides copy-on-write cloning and snapshotting for instant VM creation.
  """

  require Logger

  @doc """
  Clone a base image to create a new VM overlay.

  Uses BTRFS snapshot for instant CoW clone.
  """
  def clone(base_image, vm_id) do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    source = Path.join([btrfs_root, "@base", base_image])
    dest_dir = Path.join([btrfs_root, "@vms", vm_id])
    dest = Path.join(dest_dir, "overlay")

    with :ok <- ensure_dir(dest_dir),
         :ok <- snapshot(source, dest) do
      {:ok, dest}
    end
  end

  @doc """
  Create a read-only snapshot of a VM's overlay.
  """
  def snapshot_readonly(vm_id, snapshot_name) do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    source = Path.join([btrfs_root, "@vms", vm_id, "overlay"])
    dest = Path.join([btrfs_root, "@vms", vm_id, ".snapshots", snapshot_name])

    with :ok <- ensure_dir(Path.dirname(dest)) do
      snapshot(source, dest, readonly: true)
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

  defp snapshot(source, dest, opts \\ []) do
    args =
      if opts[:readonly] do
        ["subvolume", "snapshot", "-r", source, dest]
      else
        ["subvolume", "snapshot", source, dest]
      end

    case System.cmd("btrfs", args, stderr_to_stdout: true) do
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
    # Format: "ID 256 gen 123 top level 5 path @base/debian-12"
    case Regex.run(~r/path (.+)$/, line) do
      [_, path] -> path
      _ -> nil
    end
  end
end
