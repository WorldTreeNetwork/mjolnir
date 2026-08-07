defmodule Mjolnir.Gateway.RouteReconciler do
  @moduledoc """
  Keeps the gateway local-route drop-in (`Mjolnir.Gateway.Routes`) fresh.

  Subscribes to `Mjolnir.EventBus` (`:all`) and re-renders the drop-in on VM
  lifecycle changes, on deploy cutover (`trigger/0`, called from
  `Mjolnir.Deploy.Runtime` after the registry write), and once on boot. Renders
  are **debounced** (default 500ms) so a burst of events coalesces into a single
  write + `systemctl reload`.

  Started only when `:gateway_routes_enabled` is true (see
  `Mjolnir.Application`); `trigger/0` is a safe no-op when it is not running, so
  callers never need to know whether the feature is on.
  """

  use GenServer
  require Logger

  alias Mjolnir.Gateway.Routes

  @debounce_ms 500

  # Re-render at these delays after boot (mjolnir-do5).
  #
  # The boot render fires long before service VMs finish resuming, so it sees
  # them as not-running and emits NO route for their custom domains — and
  # nothing re-triggers afterwards, because `@trigger_events` only fire if some
  # OTHER VM happens to change state. On 2026-08-07 the boot render beat the
  # service VM's resume by two seconds and left startupcentral.build 400ing
  # until an operator noticed.
  #
  # Resume is not something we can wait on synchronously (VMs boot
  # independently, and a wedged one may never arrive), so sweep a few times as
  # startup settles. Renders are idempotent — an unchanged route set rewrites
  # identical bytes — so extra passes are free.
  @settle_delays_ms [15_000, 60_000, 180_000]

  # EventBus events that change the set of running+local VMs, hence the routes.
  @trigger_events [:vm_spawned, :vm_started, :vm_restored, :vm_stopped, :vm_dormant]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The default post-boot settle delays.

  Exposed so a test can assert the sweep is actually ENABLED by default —
  tests that pass `:settle_delays_ms` explicitly prove the mechanism works but
  would happily pass with the default emptied, which is exactly the regression
  mjolnir-do5 is about.
  """
  @spec default_settle_delays_ms() :: [pos_integer()]
  def default_settle_delays_ms, do: @settle_delays_ms

  @doc """
  Request a debounced re-render. Safe no-op if the reconciler is not running
  (e.g. feature flag off), so deploy/runtime can call it unconditionally.
  """
  @spec trigger(GenServer.server()) :: :ok
  def trigger(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> :ok
      pid -> GenServer.cast(pid, :trigger)
    end
  end

  @impl true
  def init(opts) do
    Mjolnir.EventBus.subscribe(:all)

    state = %{
      debounce: Keyword.get(opts, :debounce_ms, @debounce_ms),
      render_opts: Keyword.get(opts, :render_opts, []),
      timer: nil
    }

    # Sweep again as startup settles, so routes for VMs that were still resuming
    # during the boot render get emitted (mjolnir-do5). Sent as a distinct
    # message so these never cancel — or get cancelled by — the debounce timer.
    for delay <- Keyword.get(opts, :settle_delays_ms, @settle_delays_ms) do
      Process.send_after(self(), :settle_render, delay)
    end

    # Reconcile once on boot (debounced, so it coalesces with any early events).
    {:ok, schedule(state)}
  end

  @impl true
  def handle_cast(:trigger, state), do: {:noreply, schedule(state)}

  @impl true
  def handle_info({:mjolnir_event, _vm_id, event, _payload}, state)
      when event in @trigger_events do
    {:noreply, schedule(state)}
  end

  def handle_info({:mjolnir_event, _vm_id, _event, _payload}, state), do: {:noreply, state}

  def handle_info(:render, state) do
    render(state)
    {:noreply, %{state | timer: nil}}
  end

  # Post-boot settle sweep. Deliberately does not touch `timer`: it is an
  # independent pass, not part of the debounce chain.
  def handle_info(:settle_render, state) do
    Logger.debug("Gateway.RouteReconciler: settle re-render")
    render(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(%{timer: timer, debounce: debounce} = state) do
    if timer, do: Process.cancel_timer(timer)
    %{state | timer: Process.send_after(self(), :render, debounce)}
  end

  defp render(%{render_opts: opts}) do
    case Routes.render_and_reload(opts) do
      {:ok, routes} ->
        Logger.debug("Gateway.RouteReconciler: rendered #{length(routes)} route(s)")

      {:error, reason} ->
        Logger.warning("Gateway.RouteReconciler: render failed: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning("Gateway.RouteReconciler: render crashed: #{Exception.message(e)}")
  end
end
