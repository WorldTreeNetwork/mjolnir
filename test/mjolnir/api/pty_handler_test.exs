defmodule Mjolnir.API.PtyHandlerTest do
  use ExUnit.Case, async: true

  alias Mjolnir.API.PtyHandler

  defmodule FakePty do
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(_), do: {:ok, nil}

    @impl true
    def handle_call({:open_pty, _rows, _cols, _session}, _from, state) do
      {:reply, {:ok, 7}, state}
    end

    def handle_call({:register_channel_handler, 7, _handler}, _from, state) do
      {:reply, :ok, state}
    end
  end

  test "ws_ping pushes a ping frame and reschedules" do
    state = %PtyHandler{vm_id: "vm", channel: 1, conn_pid: self()}
    assert {:push, {:ping, <<>>}, ^state} = PtyHandler.handle_info(:ws_ping, state)
  end

  test "a live vsock connection opens a PTY without rebuilding" do
    {:ok, conn} = FakePty.start_link()
    vm = %Mjolnir.VM{id: "not-a-registered-vm", vsock_conn: conn, state: :running}

    assert {:ok, %PtyHandler{channel: 7, conn_pid: ^conn}} =
             PtyHandler.init(%{vm: vm, vm_id: vm.id, session: "pi"})
  end

  test "a nil vsock connection fails the websocket instead of calling nil" do
    vm = %Mjolnir.VM{id: "not-a-registered-vm", vsock_conn: nil, state: :running}

    assert {:stop, :normal, {1011, message}} =
             PtyHandler.init(%{vm: vm, vm_id: vm.id, session: "pi"})

    assert message =~ "not_found"
  end

  test "a dead vsock connection fails the websocket instead of calling a corpse" do
    {:ok, conn} = FakePty.start_link()
    :ok = GenServer.stop(conn)
    vm = %Mjolnir.VM{id: "not-a-registered-vm", vsock_conn: conn, state: :running}

    assert {:stop, :normal, {1011, message}} =
             PtyHandler.init(%{vm: vm, vm_id: vm.id, session: "pi"})

    assert message =~ "not_found"
  end

  test "a busy VM is not rebuilt from the websocket" do
    vm = %Mjolnir.VM{
      id: "not-a-registered-vm",
      vsock_conn: nil,
      state: :running,
      exec_inflight: %{make_ref() => true}
    }

    assert {:stop, :normal, {1011, message}} =
             PtyHandler.init(%{vm: vm, vm_id: vm.id, session: "pi"})

    assert message =~ "vm_busy"
  end

  test "a VM that is not running is not rebuilt from the websocket" do
    vm = %Mjolnir.VM{id: "not-a-registered-vm", vsock_conn: nil, state: :booting}

    assert {:stop, :normal, {1011, message}} =
             PtyHandler.init(%{vm: vm, vm_id: vm.id, session: "pi"})

    assert message =~ "vm_not_running"
  end
end
