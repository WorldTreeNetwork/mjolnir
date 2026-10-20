defmodule Mjolnir.Cleanup do
  @moduledoc """
  Startup sweep. Does not kill a process because its command line contains
  the socket directory. Socket unlink of an attached or unclassified scope
  waits for reattach. Disks with a state record and this instance's DOWN
  TAPs are still handled here.
  """

  require Logger

  @hypervisor_process_names ["cloud-hypervisor", "virtiofsd"]

  def sweep do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    clean_stale_vms(btrfs_root)
    clean_orphan_taps()
    reap_trash()

    :ok
  end

  defp reap_trash do
    case Mjolnir.BTRFS.reap_trash() do
      {:ok, _n} -> :ok
      {:error, reason} -> Logger.warning("Trash reap failed: #{inspect(reason)}")
    end
  rescue
    _ -> :ok
  end

  @doc false
  def hypervisor_process_names, do: @hypervisor_process_names

  # Delete our own DOWN TAP interfaces.
  #
  # TAP devices are host-global. Scoping to :tap_prefix means each BEAM only
  # reaps interfaces it could have created (mjolnir-0ut).
  defp clean_orphan_taps do
    prefix = Mjolnir.Network.tap_prefix()
    pattern = Regex.compile!("(#{Regex.escape(prefix)}[a-f0-9]+)")

    case System.cmd("ip", ["-o", "link", "show"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(fn line ->
          String.contains?(line, prefix) and String.contains?(line, "state DOWN")
        end)
        |> Enum.each(fn line ->
          case Regex.run(pattern, line) do
            [_, tap_name] ->
              Logger.info("Removing orphan TAP interface: #{tap_name}")
              System.cmd("sudo", ["-n", "ip", "link", "del", tap_name], stderr_to_stdout: true)

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
        Enum.each(entries, &maybe_remove_vm(vms_dir, &1))

      {:error, :enoent} ->
        :ok
    end
  end

  defp reserved_entry?(entry), do: String.starts_with?(entry, ".")

  defp maybe_remove_vm(_vms_dir, entry) when entry in ["", "."], do: :ok

  defp maybe_remove_vm(vms_dir, entry) do
    path = Path.join(vms_dir, entry)

    cond do
      reserved_entry?(entry) ->
        Logger.debug("Skipping reserved entry in @vms: #{entry}")

      true ->
        case safe_state_lookup(entry) do
          {:ok, record} ->
            Logger.info(
              "Preserving VM subvolume #{entry} (intent=#{record.intent}) for reconcile"
            )

          :not_found ->
            Logger.info("Trashing stale VM directory: #{path}")
            _ = Mjolnir.BTRFS.trash_subvolume(path)

          :unknown ->
            Logger.warning(
              "Cannot consult StateStore for #{entry}; PRESERVING subvolume (fail-safe). " <>
                "Will retry on next sweep."
            )
        end
    end
  end

  defp safe_state_lookup(uuid) do
    Mjolnir.StateStore.get(uuid)
  rescue
    ArgumentError -> :unknown
  end
end
