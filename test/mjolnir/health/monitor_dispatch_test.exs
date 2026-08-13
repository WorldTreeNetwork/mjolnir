defmodule Mjolnir.Health.MonitorDispatchTest do
  @moduledoc """
  The monitor's result dispatch must survive every shape `Health.check/1` can
  return. `{:error, :unreachable}` is a *documented* pass-through return, but it
  had no clause here — so a single wedged VM raised CaseClauseError and aborted
  the whole tick, skipping every remaining VM and the trash reap.

  Observed in prod 2026-07-21 13:04:03 immediately after deploy.

  Only the shapes that do not attempt a heal are exercised — the heal paths
  reach a live VM registry and belong to the integration suite.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mjolnir.Health.Monitor

  @vm_id "vm-under-test"

  test ":ok is silent" do
    log = capture_log(fn -> Monitor.handle_check_result(@vm_id, {:ok, %{overall: :ok}}) end)
    refute log =~ "Health.Monitor"
  end

  test "{:error, :not_found} is silent — the VM simply went away" do
    log = capture_log(fn -> Monitor.handle_check_result(@vm_id, {:error, :not_found}) end)
    refute log =~ "Health.Monitor"
  end

  test "{:error, :unreachable} warns instead of raising" do
    log =
      capture_log(fn ->
        assert Monitor.handle_check_result(@vm_id, {:error, :unreachable})
      end)

    assert log =~ "GenServer unreachable"
    assert log =~ @vm_id
  end

  test ":booting does not heal and does not warn" do
    # mjolnir-y32: before the unlock moved off the VM process, a booting
    # :managed VM could not answer at all and the monitor logged
    # "GenServer unreachable" on every deploy — the loudest possible line for
    # a VM that was fine. Now it answers :booting, and the right response is
    # to say nothing at warning level and heal nothing.
    log = capture_log(fn -> Monitor.handle_check_result(@vm_id, {:ok, %{overall: :booting}}) end)

    refute log =~ "unreachable"
    refute log =~ "[warning]"
    refute log =~ "unexpected check result"
  end

  test "an unanticipated result shape is logged, not raised" do
    # The regression guard: whatever future shape appears, the tick survives.
    log =
      capture_log(fn ->
        assert Monitor.handle_check_result(@vm_id, {:error, :some_future_reason})
      end)

    assert log =~ "unexpected check result"
  end
end
