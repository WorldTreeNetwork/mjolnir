defmodule Mjolnir.Forge.EventsTest do
  @moduledoc """
  Serialization + emission semantics for `Mjolnir.Forge.Events`. Not async —
  `emit/1` writes through the shared `AuditLog` and `:forge_state_dir`.
  """

  use ExUnit.Case, async: false

  alias Mjolnir.Forge.{AuditLog, EventBus, Events}

  @kind Mjolnir.Forge.Resource.SystemdUnit

  setup do
    n = System.unique_integer([:positive])
    state_dir = Path.join(System.tmp_dir!(), "forge-events-#{n}")
    File.mkdir_p!(state_dir)

    prev = Application.get_env(:mjolnir, :forge_state_dir)
    Application.put_env(:mjolnir, :forge_state_dir, state_dir)

    on_exit(fn ->
      Application.put_env(:mjolnir, :forge_state_dir, prev)
      EventBus.unsubscribe(:all)
      _ = File.rm_rf(state_dir)
    end)

    %{state_dir: state_dir}
  end

  defp entry(status), do: %{kind: @kind, id: "x.service", status: status}

  describe "serialization" do
    test "to_json/from_json round-trips an event" do
      ev = %{Events.new(host: "self", type: :drift, kind: "systemd_unit", status: "new") | id: 42}
      back = ev |> Events.to_json() |> Events.from_json()

      assert back.id == 42
      assert back.type == :drift
      assert back.host == "self"
      assert back.kind == "systemd_unit"
      assert back.status == "new"
    end

    test "to_sse/1 produces a well-formed frame" do
      ev = %{Events.new(host: "self", type: :probe) | id: 7}
      frame = Events.to_sse(ev)

      assert frame =~ "id: 7\n"
      assert frame =~ "event: probe\n"
      assert frame =~ ~r/data: \{.*\}\n/
      # Frames are terminated by a blank line.
      assert String.ends_with?(frame, "\n\n")
    end
  end

  describe "emit/1" do
    test "appends to the audit log and publishes to subscribers" do
      EventBus.subscribe(:all)
      emitted = Events.emit(host: "self", type: :probe)

      # Published live...
      assert_receive {:forge_event, %Events.Event{id: id, type: :probe}}, 500
      assert id == emitted.id

      # ...and durably appended.
      assert Enum.any?(AuditLog.recent(10), &(&1.id == emitted.id))
    end
  end

  describe "builders" do
    test "probe/2 emits a single summary with status counts" do
      EventBus.subscribe(:all)
      entries = [entry(:new), entry(:new), entry(:converged)]

      Events.probe("self", entries)

      assert_receive {:forge_event, %Events.Event{type: :probe, detail: detail}}, 500
      assert detail.total == 3
      assert detail.counts["new"] == 2
      assert detail.counts["converged"] == 1
    end

    test "drift/2 emits one event per drift-status entry and skips converged" do
      entries = [entry(:new), entry(:converged), entry(:drifted)]
      emitted = Events.drift("self", entries)

      statuses = Enum.map(emitted, & &1.status)
      assert "new" in statuses
      assert "drifted" in statuses
      refute "converged" in statuses
      assert length(emitted) == 2
    end

    test "apply_outcome/3 tags converged as :adopt, others as :apply" do
      adopt = Events.apply_outcome("self", entry(:converged), :ok)
      assert adopt.type == :adopt
      assert adopt.detail.result == "ok"

      applied = Events.apply_outcome("self", entry(:new), :ok)
      assert applied.type == :apply
      assert applied.detail.result == "ok"
    end

    test "apply_outcome/3 records error reasons" do
      ev = Events.apply_outcome("self", entry(:new), {:error, :boom})
      assert ev.detail.result == "error"
      assert ev.detail.reason =~ "boom"
    end
  end
end
