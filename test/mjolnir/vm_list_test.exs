defmodule Mjolnir.VMListTest do
  @moduledoc """
  `Mjolnir.VM.list/0` must never silently drop a registered VM whose GenServer
  is momentarily unresponsive — that made a live VM look destroyed in
  `mj list`/`info`/`url` (mjolnir-l4i). A blocked VM is surfaced as a degraded
  `:unreachable` placeholder instead of vanishing.
  """
  use ExUnit.Case, async: false

  alias Mjolnir.VMRegistry

  setup do
    # Shrink the per-VM probe timeout so the "blocked GenServer" case resolves
    # in milliseconds rather than the 5s production default.
    prev = Application.get_env(:mjolnir, :vm_list_probe_timeout_ms)
    Application.put_env(:mjolnir, :vm_list_probe_timeout_ms, 100)
    on_exit(fn -> restore(:vm_list_probe_timeout_ms, prev) end)
    :ok
  end

  test "a registered but unresponsive VM appears as :unreachable, not dropped" do
    id = "unreachable-#{System.unique_integer([:positive])}"
    register_blocked(id)

    entry = Enum.find(Mjolnir.VM.list(), &(&1.id == id))
    assert %Mjolnir.VM{state: :unreachable} = entry
  end

  test "an unreachable placeholder carries owner_id from StateStore so the owner can still see it" do
    alias Mjolnir.StateStore
    alias Mjolnir.StateStore.Record

    tmp =
      Path.join([
        System.tmp_dir!(),
        "mjolnir-vm-list-test",
        "#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(Path.join(tmp, "quarantine"))
    prev_state = Application.get_env(:mjolnir, :state_dir)
    Application.put_env(:mjolnir, :state_dir, tmp)
    :ok = StateStore.reload()

    on_exit(fn ->
      File.rm_rf!(tmp)
      if prev_state, do: Application.put_env(:mjolnir, :state_dir, prev_state)
      :ok = StateStore.reload()
    end)

    id = "owned-#{System.unique_integer([:positive])}"
    :ok = StateStore.put(Record.new(id, :running, spawn_config: %{"owner_id" => "alice"}))
    register_blocked(id)

    entry = Enum.find(Mjolnir.VM.list(), &(&1.id == id))
    assert %Mjolnir.VM{state: :unreachable, owner_id: "alice"} = entry
  end

  test "a responsive VM is returned with its real state alongside an unreachable one" do
    healthy_id = "healthy-#{System.unique_integer([:positive])}"
    blocked_id = "blocked-#{System.unique_integer([:positive])}"

    # A tiny GenServer that speaks the :get_state protocol like a real VM.
    # start_supervised ensures ExUnit tears it down (and deregisters it).
    {:ok, _} =
      start_supervised(
        {Mjolnir.VMListTest.Responder, healthy_id},
        id: :responder
      )

    register_blocked(blocked_id)

    list = Mjolnir.VM.list()
    assert %Mjolnir.VM{state: :running} = Enum.find(list, &(&1.id == healthy_id))
    assert %Mjolnir.VM{state: :unreachable} = Enum.find(list, &(&1.id == blocked_id))
  end

  # Spawn a bare process that registers itself under `id` and never answers
  # :get_state. Blocks until registration is confirmed, and registers a cleanup
  # that kills it and waits for the registry entry to disappear — so no ghost
  # leaks into the next test (VM.list reads the shared VMRegistry).
  defp register_blocked(id) do
    test_pid = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(VMRegistry, id, nil)
        send(test_pid, {:registered, id})
        Process.sleep(:infinity)
      end)

    assert_receive {:registered, ^id}, 1_000

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      wait_until(fn -> Registry.lookup(VMRegistry, id) == [] end)
    end)

    pid
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: :timeout

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:mjolnir, key)
  defp restore(key, val), do: Application.put_env(:mjolnir, key, val)

  defmodule Responder do
    @moduledoc false
    use GenServer

    def start_link(id),
      do: GenServer.start_link(__MODULE__, id, name: {:via, Registry, {VMRegistry, id}})

    @impl true
    def init(id), do: {:ok, %Mjolnir.VM{id: id, state: :running}}

    @impl true
    def handle_call(:get_state, _from, state), do: {:reply, state, state}
  end
end
