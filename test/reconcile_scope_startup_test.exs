defmodule Mjolnir.ReconcileScopeStartupTest do
  use ExUnit.Case, async: false

  alias Mjolnir.Reconcile
  alias Mjolnir.StateStore.Record

  setup_all do
    if Process.whereis(Mjolnir.VMRegistry) == nil do
      start_supervised!({Registry, keys: :unique, name: Mjolnir.VMRegistry})
    end

    :ok
  end

  test "a booting VM without a durable record keeps its scope without a state call" do
    id = "booting-#{System.unique_integer([:positive])}"
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(Mjolnir.VMRegistry, id, nil)
        send(parent, :registered)
        # Deliberately never answer a GenServer call while booting.
        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive :registered
    task = Task.async(fn -> Reconcile.scope_should_stop?(id, :not_found) end)
    refute Task.await(task, 1_000)
  end

  test "a genuinely unregistered orphan is still stopped" do
    assert Reconcile.scope_should_stop?(
             "orphan-#{System.unique_integer([:positive])}",
             :not_found
           )
  end

  test "explicit terminal intents are respected even with a registered process" do
    id = "terminal-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(Mjolnir.VMRegistry, id, nil)

    for intent <- [:stopped, :failed, :dormant] do
      assert Reconcile.scope_should_stop?(id, {:ok, Record.new(id, intent)})
    end
  end

  test "running records and unreadable state are preserved" do
    refute Reconcile.scope_should_stop?("running", {:ok, Record.new("running", :running)})
    refute Reconcile.scope_should_stop?("unknown", {:error, :unavailable})
  end
end
