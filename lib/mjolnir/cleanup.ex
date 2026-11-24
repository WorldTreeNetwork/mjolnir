defmodule Mjolnir.Cleanup do
  @moduledoc """
  Startup sweep. Does not kill a process because its command line contains
  the socket directory. Socket cleanup preserves scopes that may still own a guest.
  Disks with a state record and this instance's DOWN TAPs are still handled here. Published-port rules of VMs with no
  `:running` record are removed.
  """

  require Logger

  @hypervisor_process_names ["cloud-hypervisor", "virtiofsd"]

  def sweep do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    sweep_sockets(Application.fetch_env!(:mjolnir, :socket_dir), Mjolnir.VmmScope.list_scopes())
    clean_stale_vms(btrfs_root)
    clean_orphan_taps()
    clean_published_ports()
    reap_trash()

    :ok
  end

  # This sweep runs synchronously before VMRegistry and VMSupervisor start.
  # An active controller cannot infer socket ownership from scopes alone.
  @doc false
  def sweep_sockets(_socket_dir, {:error, :unlisted}), do: :ok

  def sweep_sockets(socket_dir, {:ok, scopes}) do
    protected = for {id, state} <- scopes, state not in ["inactive", "failed"], do: id

    case File.ls(socket_dir) do
      {:ok, files} ->
        Enum.each(files, fn file ->
          # A unikernel's entity key file lives only for its boot. One found
          # here is from a boot this BEAM no longer runs: always remove it.
          if String.ends_with?(file, ".entity-key"), do: File.rm(Path.join(socket_dir, file))
          # The 0700 directory `Mjolnir.Unikernel.write_private/2` writes in,
          # left only if the BEAM died mid-write.
          if String.starts_with?(file, ".private-"), do: File.rm_rf(Path.join(socket_dir, file))

          stale = String.ends_with?(file, ".sock") or String.ends_with?(file, "_vsock")

          if stale and not Mjolnir.VmmScope.socket_protected?(file, protected) do
            File.rm(Path.join(socket_dir, file))
          end
        end)

      _ ->
        :ok
    end
  end

  # Published-port rules whose VM has no :running record. A VM that is
  # still alive in its scope keeps its record, so its rules stay and the
  # adopting process re-checks them.
  defp clean_published_ports do
    _ = Mjolnir.PublishedPorts.sweep()
    :ok
  rescue
    _ -> :ok
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
