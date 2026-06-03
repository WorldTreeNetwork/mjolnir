defmodule Mjolnir.Forge.AuditLogTest do
  @moduledoc """
  Append-only JSONL persistence + replay for `Mjolnir.Forge.AuditLog`. Not
  async — the GenServer and `:forge_state_dir` are global singletons.
  """

  use ExUnit.Case, async: false

  alias Mjolnir.Forge.{AuditLog, Events}

  setup do
    n = System.unique_integer([:positive])
    state_dir = Path.join(System.tmp_dir!(), "forge-audit-#{n}")
    File.mkdir_p!(state_dir)

    prev = Application.get_env(:mjolnir, :forge_state_dir)
    Application.put_env(:mjolnir, :forge_state_dir, state_dir)

    on_exit(fn ->
      Application.put_env(:mjolnir, :forge_state_dir, prev)
      _ = File.rm_rf(state_dir)
    end)

    %{state_dir: state_dir}
  end

  defp append(host, type), do: AuditLog.append(Events.new(host: host, type: type))

  test "append stamps a strictly monotonic id" do
    a = append("self", :probe)
    b = append("self", :probe)
    c = append("self", :probe)

    assert is_integer(a.id)
    assert a.id < b.id
    assert b.id < c.id
  end

  test "recent/1 returns events in append order" do
    append("self", :probe)
    append("self", :drift)
    append("self", :apply)

    types = AuditLog.recent(10) |> Enum.map(& &1.type)
    assert types == [:probe, :drift, :apply]
  end

  test "recent/1 takes only the last N" do
    for _ <- 1..5, do: append("self", :probe)
    assert length(AuditLog.recent(2)) == 2
  end

  test "since/1 returns only events after the cursor" do
    a = append("self", :probe)
    b = append("self", :drift)
    c = append("self", :apply)

    after_a = AuditLog.since(a.id) |> Enum.map(& &1.id)
    assert after_a == [b.id, c.id]
  end

  test "since/0-equivalent (cursor 0) returns the whole log" do
    append("self", :probe)
    append("self", :drift)
    assert length(AuditLog.since(0)) == 2
  end

  test "reading a missing log returns []" do
    assert AuditLog.recent(10) == []
    assert AuditLog.since(0) == []
  end

  test "the log file lands under <state_dir>/_events/", %{state_dir: state_dir} do
    append("self", :probe)
    assert AuditLog.path() == Path.join([state_dir, "_events", "audit.jsonl"])
    assert File.exists?(AuditLog.path())
  end

  test "persisted lines round-trip back into Event structs (id/type preserved)" do
    a = append("roundtrip", :apply)
    [reloaded] = AuditLog.since(a.id - 1)
    assert reloaded.id == a.id
    assert reloaded.type == :apply
    assert reloaded.host == "roundtrip"
  end
end
