defmodule Mjolnir.Cleanup do
  @moduledoc """
  Cleans up orphaned hypervisor processes and stale files from previous runs.

  Called once during application startup, before the supervision tree starts.
  Finds hypervisor processes whose `--api-sock` points to our socket directory
  and kills them.
  """

  require Logger

  @hypervisor_process_names ["firecracker", "cloud-hypervisor"]

  def sweep do
    socket_dir = Application.get_env(:mjolnir, :socket_dir)
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)

    orphans = find_orphan_hypervisors(socket_dir)

    if orphans != [] do
      Logger.info("Found #{length(orphans)} orphaned hypervisor process(es), cleaning up")

      Enum.each(orphans, fn {pid, vm_id} ->
        Logger.info("Killing orphaned hypervisor PID #{pid} (VM #{vm_id})")
        System.cmd("kill", [to_string(pid)])
      end)
    end

    clean_stale_sockets(socket_dir)
    clean_stale_vms(btrfs_root)
    clean_orphan_taps()

    :ok
  end

  defp find_orphan_hypervisors(socket_dir) do
    case System.cmd("ps", ["-eo", "pid,ppid,args"], stderr_to_stdout: true) do
      {output, 0} ->
        lines = String.split(output, "\n")

        @hypervisor_process_names
        |> Enum.flat_map(fn process_name ->
          lines
          |> Enum.filter(&String.contains?(&1, process_name))
          |> Enum.reject(&String.contains?(&1, "grep"))
          |> Enum.filter(&String.contains?(&1, socket_dir))
          |> Enum.map(&parse_hypervisor_process/1)
          |> Enum.reject(&is_nil/1)
        end)

      _ ->
        []
    end
  end

  defp parse_hypervisor_process(line) do
    cond do
      # Firecracker: --id <vm_id>
      match = Regex.run(~r/^\s*(\d+)\s+\d+\s+.*--id\s+(\S+)/, line) ->
        [_, pid, vm_id] = match
        {String.to_integer(pid), vm_id}

      # Cloud Hypervisor: --api-socket /path/<uuid>.sock
      match =
          Regex.run(
            ~r/^\s*(\d+)\s+\d+\s+.*--api-socket\s+\S*\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.sock/,
            line
          ) ->
        [_, pid, vm_id] = match
        {String.to_integer(pid), vm_id}

      # Fallback: any UUID pattern in the command line (less reliable but better than nothing)
      match =
          Regex.run(
            ~r/^\s*(\d+)\s+\d+\s+.*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/,
            line
          ) ->
        [_, pid, vm_id] = match
        {String.to_integer(pid), vm_id}

      true ->
        nil
    end
  end

  defp clean_stale_sockets(socket_dir) do
    case File.ls(socket_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(fn file ->
          String.ends_with?(file, ".sock") or String.ends_with?(file, "_vsock")
        end)
        |> Enum.each(fn file ->
          path = Path.join(socket_dir, file)
          Logger.debug("Removing stale socket: #{path}")
          File.rm(path)
        end)

      {:error, :enoent} ->
        :ok
    end
  end

  defp clean_orphan_taps do
    # Find any mj-* TAP interfaces with state DOWN and delete them
    case System.cmd("ip", ["-o", "link", "show"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(fn line ->
          String.contains?(line, "mj-") and String.contains?(line, "state DOWN")
        end)
        |> Enum.each(fn line ->
          case Regex.run(~r/(mj-[a-f0-9]+)/, line) do
            [_, tap_name] ->
              Logger.info("Removing orphan TAP interface: #{tap_name}")
              System.cmd("ip", ["link", "del", tap_name], stderr_to_stdout: true)

            _ ->
              :ok
          end
        end)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
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
