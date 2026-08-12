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

      # Reclaim CI VMs whose server-side lease expired (mjolnir-urp).
      #
      # Ordered after Reconcile so that either shape of orphan has a live
      # GenServer to stop through the normal teardown path. Both occur: when
      # the runner was SIGKILLed mid-job (mjolnir-24r, reproduced 2026-08-12)
      # the VM stayed fully alive and answering execs — only its OWNER died —
      # while a record stranded across a Mjolnir restart has no GenServer
      # until Reconcile rehydrates it. Reclaiming is the same operation
      # either way; this ordering just guarantees something is there to stop.
      #
      # Isolated in its own rescue so a bug here can never blind this tick to
      # probes or trash reaping.
      try do
        Mjolnir.CILease.sweep()
      rescue
        e -> Logger.error("Health.Monitor: CI lease sweep raised: #{inspect(e)}")
      end

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

    # Isolate per-VM failures: the tick-level rescue is too coarse — one VM
    # raising there skips every *later* VM plus the trash reap. Contain it here
    # so a single sick VM can't blind the monitor to the rest of the fleet.
    Enum.each(vm_ids, fn vm_id ->
      try do
        probe_one(vm_id)
      rescue
        e -> Logger.error("Health.Monitor: probe of #{vm_id} raised: #{inspect(e)}")
      end
    end)
  end

  defp probe_one(vm_id), do: handle_check_result(vm_id, Mjolnir.Health.check(vm_id))

  # Split from the probe call so every result shape is unit-testable without a
  # live VM registry — the CaseClauseError this replaced was only reachable in
  # production precisely because this dispatch had no seam.
  @doc false
  def handle_check_result(vm_id, result) do
    case result do
      {:ok, %{overall: :ok}} ->
        :ok

      {:ok, %{overall: :degraded} = report} ->
        # Name the failing checks — a bare "degraded" sends the reader digging
        # through four subsystems to find which one broke (mjolnir-nf6).
        Logger.warning(
          "Health.Monitor: VM #{vm_id} degraded (" <>
            Enum.join(Mjolnir.Health.failing_check_names(report.checks), ", ") <>
            "), attempting L1 heal"
        )

        Mjolnir.EventBus.publish(vm_id, :vm_unhealthy, report)
        _ = Mjolnir.Health.heal(vm_id, max_level: 1)

      {:ok, %{overall: :busy}} ->
        # An exec we dispatched is still running. The probes fail because the
        # guest is busy doing what we asked, and healing would stop the very
        # vsock connection that exec is blocked on (mjolnir-1s9). Say nothing at
        # warning level: this is a normal state during any long build.
        Logger.debug("Health.Monitor: VM #{vm_id} busy with an in-flight exec; not healing")

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

      # The VM's GenServer is registered but not answering (mjolnir-8ie).
      # Health.check/1 documents this as a pass-through return, but it used to
      # fall off the end of this case and raise CaseClauseError, aborting the
      # whole tick. It's a real signal — a wedged VM process — so surface it,
      # but there is nothing to heal through: every heal path also goes via
      # VM.get and would hit the same wall.
      {:error, :unreachable} ->
        Logger.warning(
          "Health.Monitor: VM #{vm_id} GenServer unreachable (call timed out); " <>
            "skipping probe this tick"
        )

        Mjolnir.EventBus.publish(vm_id, :vm_unreachable, %{vm_id: vm_id})

      # Never let an unanticipated return shape take down the tick.
      other ->
        Logger.error("Health.Monitor: unexpected check result for #{vm_id}: #{inspect(other)}")
    end
  end
end
