defmodule Mjolnir.Health.Monitor do
  @moduledoc """
  Periodic background health check for every registered VM.

  Every `interval_ms` (default 30s), the monitor scans `Mjolnir.VMRegistry`
  and runs `Mjolnir.Health.check/1` on each VM. On `:degraded`, it attempts
  an L1 auto-heal. On `:agent_unreachable` (guest agent silent on vsock but the
  VM is provably TCP-live), it attempts an L1 vsock heal rather than declaring
  death. On `:dead` (unreachable over *both* vsock and TCP), it emits an
  `EventBus` event and stops escalating — a human decides the next step.

  This is the "slow catch" layer for the connection-rot problem: even if
  nothing actively pokes a VM, the monitor notices a stale Iroh or vsock
  within 30s and reconnects.
  """

  use GenServer
  require Logger

  @default_interval_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    enabled? = Keyword.get(opts, :enabled, true)

    if enabled?, do: schedule_tick(interval)

    {:ok, %{interval_ms: interval, enabled?: enabled?, last_tick: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      # Catch L4/L5 failures: any VM whose GenServer died (e.g. hypervisor
      # crashed, was SIGKILLed) has a StateStore record but no registry
      # entry. Reconcile.run is idempotent — skips healthy VMs silently.
      Mjolnir.Reconcile.run()

      # Per-VM L0–L2 probes + auto-heal on :degraded.
      probe_all_vms()

      # Reclaim soft-deleted subvolumes past their retention window.
      _ = Mjolnir.BTRFS.reap_trash()
    rescue
      e -> Logger.error("Health.Monitor tick raised: #{inspect(e)}")
    end

    schedule_tick(state.interval_ms)
    {:noreply, %{state | last_tick: System.system_time(:millisecond)}}
  end

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)

  defp probe_all_vms do
    vm_ids =
      Registry.select(Mjolnir.VMRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1"}}]}])
      |> Enum.map(fn {id} -> id end)

    Enum.each(vm_ids, &probe_one/1)
  end

  defp probe_one(vm_id) do
    case Mjolnir.Health.check(vm_id) do
      {:ok, %{overall: :ok}} ->
        :ok

      {:ok, %{overall: :degraded} = report} ->
        Logger.warning("Health.Monitor: VM #{vm_id} degraded, attempting L1 heal")
        Mjolnir.EventBus.publish(vm_id, :vm_unhealthy, report)
        _ = Mjolnir.Health.heal(vm_id, max_level: 1)

      {:ok, %{overall: :agent_unreachable} = report} ->
        # The guest agent is unreachable over vsock, but an independent TCP probe
        # confirmed the VM is alive and serving. This is NOT death — it's a
        # wedged vsock/agent channel (the mjolnir-8ie signature). Attempt the L1
        # heal (rebuild the vsock connection) instead of crying DEAD.
        Logger.warning(
          "Health.Monitor: VM #{vm_id} guest-agent unreachable over vsock but VM is TCP-live; " <>
            "attempting L1 vsock heal (not declaring DEAD)"
        )

        Mjolnir.EventBus.publish(vm_id, :vm_agent_unreachable, report)
        _ = Mjolnir.Health.heal(vm_id, max_level: 1)

      {:ok, %{overall: :dead} = report} ->
        Logger.error(
          "Health.Monitor: VM #{vm_id} DEAD (unreachable over vsock AND TCP), not auto-healing"
        )

        Mjolnir.EventBus.publish(vm_id, :vm_unhealthy, report)

      {:error, :not_found} ->
        :ok
    end
  end
end
