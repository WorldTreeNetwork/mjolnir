defmodule Mjolnir.Cleanup do
  @moduledoc """
  Cleans up orphaned Firecracker processes and stale files from previous runs.

  Called once during application startup, before the supervision tree starts.
  Finds Firecracker processes whose `--api-sock` points to our socket directory
  and kills them.
  """

  require Logger

  def sweep do
    socket_dir = Application.get_env(:mjolnir, :socket_dir)
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)

    orphans = find_orphan_firecrackers(socket_dir)

    if orphans != [] do
      Logger.info("Found #{length(orphans)} orphaned Firecracker process(es), cleaning up")

      Enum.each(orphans, fn {pid, vm_id} ->
        Logger.info("Killing orphaned Firecracker PID #{pid} (VM #{vm_id})")
        System.cmd("kill", [to_string(pid)])
      end)
    end

    clean_stale_sockets(socket_dir)
    clean_stale_vms(btrfs_root)

    :ok
  end

  defp find_orphan_firecrackers(socket_dir) do
    case System.cmd("ps", ["-eo", "pid,ppid,args"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "firecracker"))
        |> Enum.filter(&String.contains?(&1, socket_dir))
        |> Enum.map(&parse_firecracker_process/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp parse_firecracker_process(line) do
    case Regex.run(~r/^\s*(\d+)\s+\d+\s+.*--id\s+(\S+)/, line) do
      [_, pid, vm_id] -> {String.to_integer(pid), vm_id}
      _ -> nil
    end
  end

  defp clean_stale_sockets(socket_dir) do
    case File.ls(socket_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".sock"))
        |> Enum.each(fn file ->
          path = Path.join(socket_dir, file)
          Logger.debug("Removing stale socket: #{path}")
          File.rm(path)
        end)

      {:error, :enoent} ->
        :ok
    end
  end

  defp clean_stale_vms(btrfs_root) do
    vms_dir = Path.join(btrfs_root, "@vms")

    case File.ls(vms_dir) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          path = Path.join(vms_dir, entry)
          Logger.info("Removing stale VM directory: #{path}")
          File.rm_rf(path)
        end)

      {:error, :enoent} ->
        :ok
    end
  end
end
