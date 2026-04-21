defmodule Mjolnir.Health do
  @moduledoc """
  Probe-and-heal coordinator for Mjolnir VMs and the host.

  Design lives in `docs/plans/durability.md`. Briefly:

  - Per-VM checks are registered at levels 0..5. `check/1` runs them all
    for a given VM and returns a report. `heal/2` runs probes and, for
    each `:degraded` or `:dead` finding, invokes the matching `heal/1`
    callback up to `max_level`.
  - Host-wide checks live in `Mjolnir.Health.Host` and are independent.
  - `nuke/1` is the escape hatch — it triggers L5 (subvolume rebuild).
    Currently unimplemented; left as a stub so the API shape is stable.
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

  @spec nuke(String.t()) :: {:error, :not_implemented}
  def nuke(vm_id) when is_binary(vm_id) do
    Logger.warning("Health.nuke/1 not implemented yet for #{vm_id}")
    {:error, :not_implemented}
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
end
