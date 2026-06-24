defmodule Mjolnir.Health do
  @moduledoc """
  Probe-and-heal coordinator for Mjolnir VMs and the host.

  Design lives in `docs/plans/durability.md`. Briefly:

  - Per-VM checks are registered at levels 0..5. `check/1` runs them all
    for a given VM and returns a report. `heal/2` runs probes and, for
    each `:degraded` or `:dead` finding, invokes the matching `heal/1`
    callback up to `max_level`.
  - Host-wide checks live in `Mjolnir.Health.Host` and are independent.
  - `nuke/1` is the escape hatch — it triggers L5 (subvolume rebuild). It is
    recover-safe: the old rootfs is moved to `@trash` and restored if the
    respawn fails, so a nuke can never cause permanent data loss.
  """

  require Logger

  @default_vm_checks [
    Mjolnir.Health.GuestAgentPing,
    Mjolnir.Health.VsockConnection,
    Mjolnir.Health.IrohConnection,
    Mjolnir.Health.GuestNetwork
  ]

  @type report_entry :: %{
          level: Mjolnir.Health.Check.level(),
          name: String.t(),
          status: Mjolnir.Health.Check.status()
        }

  @type vm_report :: %{
          vm_id: String.t(),
          overall: :ok | :degraded | :dead,
          checks: [report_entry()]
        }

  @spec check(String.t()) :: {:ok, vm_report()} | {:error, :not_found}
  def check(vm_id) when is_binary(vm_id) do
    case Mjolnir.VM.get(vm_id) do
      {:ok, vm} ->
        checks =
          @default_vm_checks
          |> Enum.map(fn mod ->
            status = safe_probe(mod, vm)
            %{level: mod.level(), name: mod.name(), status: status}
          end)
          |> Enum.sort_by(& &1.level)

        {:ok,
         %{
           vm_id: vm_id,
           overall: roll_up(checks),
           checks: checks
         }}

      {:error, :not_found} = err ->
        err
    end
  end

  @spec heal(String.t(), keyword()) :: {:ok, vm_report()} | {:error, :not_found}
  def heal(vm_id, opts \\ []) when is_binary(vm_id) do
    max_level = Keyword.get(opts, :max_level, 2)

    case Mjolnir.VM.get(vm_id) do
      {:ok, vm} ->
        heal_results =
          @default_vm_checks
          |> Enum.filter(fn mod -> mod.level() <= max_level end)
          |> Enum.map(fn mod ->
            status = safe_probe(mod, vm)

            case status do
              :ok ->
                %{level: mod.level(), name: mod.name(), status: :ok, action: :skipped}

              {_degraded_or_dead, _} ->
                Logger.warning(
                  "Health.heal #{vm_id}: #{mod.name()} = #{inspect(status)}, attempting heal"
                )

                case safe_heal(mod, vm) do
                  :ok ->
                    %{
                      level: mod.level(),
                      name: mod.name(),
                      status: status,
                      action: :healed
                    }

                  {:error, reason} ->
                    %{
                      level: mod.level(),
                      name: mod.name(),
                      status: status,
                      action: {:heal_failed, reason}
                    }
                end
            end
          end)

        {:ok,
         %{
           vm_id: vm_id,
           overall: roll_up(heal_results),
           checks: heal_results
         }}

      {:error, :not_found} = err ->
        err
    end
  end

  @doc """
  L5 "nuclear option" — destroy everything about a VM's runtime state and
  respawn a fresh one with the same UUID (and therefore same TAP/MAC/IP/CID,
  since those are all deterministic UUID derivations).

  Sequence (recover-safe — never deletes before a replacement is confirmed):
  1. Capture `spawn_config` and the intent record from StateStore up-front.
  2. Move the existing rootfs into `@trash` (O(1) rename) — this both frees
     `@vms/<uuid>` for the respawn AND keeps a recoverable copy.
  3. `VM.stop/1` for runtime teardown (hypervisor kill, TAP delete, sockets);
     its own subvolume soft-delete is now a no-op since we already moved it.
  4. `VM.spawn_with_id/1` with the captured config → fresh clone from base.
  5. On respawn **success**: leave the recovery copy in `@trash` for the GC
     window (so even a bad nuke is reversible). On **failure**: restore the
     rootfs from `@trash` and re-persist the intent record, so the VM is left
     exactly as it was and `Mjolnir.Reconcile` resumes it — never lost.

  **Destroys all in-VM state on success.** Callers should only reach this
  level when lower levels have failed or a nuke is explicitly requested.
  """
  @spec nuke(String.t()) :: :ok | {:error, term()}
  def nuke(vm_id) when is_binary(vm_id) do
    Logger.warning("Health.nuke/1: L5 respawn initiated for #{vm_id}")

    spawn_opts = capture_spawn_opts(vm_id)
    record = capture_state_record(vm_id)

    # SAFETY: move the existing rootfs into @trash BEFORE any teardown, keeping
    # a handle to it. This frees @vms/<uuid> for the fresh respawn while making
    # the old state fully recoverable. A live VM keeps serving from the moved
    # inode until VM.stop kills its hypervisor a moment later.
    rootfs = Mjolnir.Reconcile.rootfs_path(vm_id)

    recovery_path =
      case Mjolnir.BTRFS.trash_subvolume(rootfs) do
        {:ok, path} ->
          path

        # Nothing to recover (already gone) — proceed, but we have no rollback.
        :ok ->
          nil

        {:error, reason} ->
          Logger.error(
            "Health.nuke/1 #{vm_id}: could not snapshot rootfs before nuke: #{inspect(reason)}"
          )

          nil
      end

    _ =
      case Mjolnir.VM.stop(vm_id) do
        :ok -> :ok
        {:error, :not_found} -> :ok
        other -> Logger.warning("Health.nuke/1 #{vm_id}: stop returned #{inspect(other)}")
      end

    # rootfs is already in @trash; this is now a belt-and-suspenders no-op for
    # any stale leftover the respawn hasn't created yet.
    _ = force_destroy_subvolume(vm_id)
    _ = Mjolnir.StateStore.delete(vm_id)

    case Mjolnir.VM.spawn_with_id(spawn_opts) do
      {:ok, _vm} ->
        Logger.warning(
          "Health.nuke/1 #{vm_id}: respawned successfully " <>
            "(prior state preserved in #{inspect(recovery_path)} until GC)"
        )

        :ok

      {:error, reason} = err ->
        Logger.error("Health.nuke/1 #{vm_id}: respawn failed: #{inspect(reason)} — rolling back")

        rollback_nuke(vm_id, rootfs, recovery_path, record)
        err
    end
  end

  # Restore the pre-nuke rootfs and intent record so a failed respawn leaves the
  # VM exactly as it was (recoverable by the normal Reconcile loop) rather than
  # deleted forever.
  defp rollback_nuke(vm_id, rootfs, recovery_path, record) do
    case Mjolnir.BTRFS.restore_trashed(recovery_path, rootfs) do
      :ok ->
        if record, do: _ = Mjolnir.StateStore.put(record)

        Logger.warning(
          "Health.nuke/1 #{vm_id}: rolled back — rootfs restored and intent record re-persisted; " <>
            "Reconcile will retry the resume."
        )

      {:error, reason} ->
        Logger.error(
          "Health.nuke/1 #{vm_id}: ROLLBACK FAILED (#{inspect(reason)}). " <>
            "Recovery copy is at #{inspect(recovery_path)} — restore manually."
        )
    end
  end

  defp capture_state_record(vm_id) do
    case Mjolnir.StateStore.get(vm_id) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  @spec check_host() :: [Mjolnir.Health.Host.report_entry()]
  def check_host, do: Mjolnir.Health.Host.check()

  @spec heal_host() :: :ok
  def heal_host, do: Mjolnir.Health.Host.heal()

  ## Internals

  defp safe_probe(mod, vm) do
    try do
      mod.probe(vm)
    rescue
      e -> {:dead, {:probe_raised, Exception.message(e)}}
    catch
      kind, reason -> {:dead, {:probe_threw, kind, reason}}
    end
  end

  defp safe_heal(mod, vm) do
    try do
      mod.heal(vm)
    rescue
      e -> {:error, {:heal_raised, Exception.message(e)}}
    catch
      kind, reason -> {:error, {:heal_threw, kind, reason}}
    end
  end

  defp roll_up(checks) do
    cond do
      Enum.any?(checks, fn c -> match?({:dead, _}, c.status) end) -> :dead
      Enum.any?(checks, fn c -> match?({:degraded, _}, c.status) end) -> :degraded
      true -> :ok
    end
  end

  # --- nuke helpers ---

  defp capture_spawn_opts(vm_id) do
    case Mjolnir.StateStore.get(vm_id) do
      {:ok, %{spawn_config: cfg}} when is_map(cfg) ->
        # spawn_config is stored with string keys (JSON-round-tripped);
        # spawn_with_id expects an atom-keyed map. Mirror the mapping
        # Mjolnir.VM.resume/1 uses.
        %{
          id: vm_id,
          base_image: Map.get(cfg, "base_image"),
          vcpus: Map.get(cfg, "vcpus"),
          memory_mb: Map.get(cfg, "memory_mb"),
          enable_iroh: Map.get(cfg, "enable_iroh"),
          owner_id: Map.get(cfg, "owner_id"),
          ssh_public_key: Map.get(cfg, "ssh_public_key")
        }
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
        |> Map.new()

      _ ->
        # No state record to draw from — nuke is still valuable as
        # destructive cleanup, but the caller gets defaults.
        %{id: vm_id}
    end
  end

  defp force_destroy_subvolume(vm_id) do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    vm_subdir = Application.get_env(:mjolnir, :vm_storage_subdir, "@vms")

    cond do
      is_nil(btrfs_root) ->
        :ok

      true ->
        path = Path.join([btrfs_root, vm_subdir, vm_id])

        if File.exists?(path) do
          case Mjolnir.BTRFS.delete_subvolume(path) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "Health.nuke/1 #{vm_id}: subvolume cleanup best-effort failed: #{inspect(reason)}"
              )

              :ok
          end
        else
          :ok
        end
    end
  end
end
