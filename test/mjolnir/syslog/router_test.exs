defmodule Mjolnir.Syslog.RouterTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Mjolnir.EventBus
  alias Mjolnir.Syslog.Message
  alias Mjolnir.Syslog.Router

  setup do
    case :pg.start_link(EventBus.pg_scope()) do
      {:ok, pid} -> on_exit(fn -> Process.exit(pid, :normal) end)
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  test "app_log default sinks are [:eventbus] only" do
    state = :sys.get_state(Router)
    assert state.app_log_sinks == [:eventbus]
  end

  test "route_app_log publishes :app_log and does not write Logger" do
    app = "app-#{System.unique_integer([:positive])}"
    EventBus.subscribe(app)

    marker = "UNIQUE_APP_LOG_#{app}"

    record = %{
      "schema" => "myscape/1",
      "app" => app,
      "msg" => marker,
      "level" => 60,
      "source" => "host"
    }

    log =
      capture_log(fn ->
        Router.route_app_log(app, record)
        :sys.get_state(Router)
      end)

    assert_receive {:mjolnir_event, ^app, :app_log, ^record}, 500
    refute log =~ marker
  end

  test "route/3 still publishes :vm_syslog and logs at emergency" do
    vm_id = "vm-#{System.unique_integer([:positive])}"
    EventBus.subscribe(vm_id)

    marker = "UNIQUE_SYSLOG_#{vm_id}"

    msg = %Message{
      raw: marker,
      message: marker,
      severity: :emergency,
      tag: "kern"
    }

    log =
      capture_log(fn ->
        Router.route(vm_id, 3, msg)
        :sys.get_state(Router)
      end)

    assert_receive {:mjolnir_event, ^vm_id, :vm_syslog, ^msg}, 500
    assert log =~ marker
  end
end
