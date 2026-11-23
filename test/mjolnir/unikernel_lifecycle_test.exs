defmodule Mjolnir.UnikernelLifecycleTest do
  use ExUnit.Case, async: false
  alias Mjolnir.{VM, StateStore}
  alias Mjolnir.StateStore.Record

  # Boot-free harness; all message admission/finish callbacks are production VM code.
  defmodule Guest do
    use GenServer

    def start_link(id),
      do: GenServer.start_link(__MODULE__, id, name: {:via, Registry, {Mjolnir.VMRegistry, id}})

    def init(id),
      do:
        {:ok,
         %VM{
           id: id,
           state: :running,
           config: %{
             guest_kind: :unikernel,
             quic_port: 30001,
             peer_pin: String.duplicate("ab", 32)
           },
           net_config: %{guest_ip: "10.0.0.2"}
         }}

    def handle_call(msg, from, state), do: VM.handle_call(msg, from, state)
    def handle_info(msg, state), do: VM.handle_info(msg, state)
  end

  setup do
    id = "unikernel-#{System.unique_integer([:positive])}"
    start_supervised!({Guest, id})
    old = Application.get_env(:mjolnir, :unikernel_exchange)

    on_exit(fn ->
      if old,
        do: Application.put_env(:mjolnir, :unikernel_exchange, old),
        else: Application.delete_env(:mjolnir, :unikernel_exchange)

      StateStore.delete(id)
    end)

    %{id: id}
  end

  test "wrong peer pin poisons subsequent attempts without another exchange", %{id: id} do
    parent = self()

    Application.put_env(:mjolnir, :unikernel_exchange, fn _ ->
      send(parent, :exchange)
      {:error, :peer_key_refused}
    end)

    assert {:error, :peer_key_refused} = VM.unikernel_message(id, <<1>>)
    assert_receive :exchange
    assert {:error, :peer_key_refused} = VM.unikernel_message(id, <<1>>)
    refute_receive :exchange
  end

  test "a second caller is refused while the first exchange holds the guest", %{id: id} do
    parent = self()

    Application.put_env(:mjolnir, :unikernel_exchange, fn _ ->
      send(parent, {:exchange, self()})

      receive do
        :finish -> {:ok, 0, <<129, 1>>}
      end
    end)

    first = Task.async(fn -> VM.unikernel_message(id, <<1>>, 5000) end)
    assert_receive {:exchange, caller}
    assert {:error, :unikernel_busy} = VM.unikernel_message(id, <<2>>)
    refute_receive {:exchange, _}
    send(caller, :finish)
    assert {:ok, 0, <<129, 1>>} = Task.await(first)
    refute GenServer.call(caller_name(id), :get_state).unikernel_busy
  end

  test "caller death releases admission", %{id: id} do
    parent = self()

    Application.put_env(:mjolnir, :unikernel_exchange, fn _ ->
      send(parent, {:exchange, self()})

      receive do
        :finish -> {:ok, 0, <<>>}
      end
    end)

    pid = spawn(fn -> VM.unikernel_message(id, <<1>>) end)
    assert_receive {:exchange, ^pid}
    Process.exit(pid, :kill)
    # synchronize on the actual monitor notification, not a timing sleep
    wait_unlocked(id, 100)
    Application.put_env(:mjolnir, :unikernel_exchange, fn _ -> {:ok, 0, <<>>} end)
    assert {:ok, 0, <<>>} = VM.unikernel_message(id, <<2>>)
  end

  test "reboot refuses before killing a live guest, and persisted records cannot resume", %{
    id: id
  } do
    record =
      Record.new(id, :running,
        spawn_config: %{"kind" => "unikernel", "restart_policy" => "never"}
      )

    :ok = StateStore.put(record)
    assert {:error, :unikernel_restart_refused} = VM.reboot(id)
    assert Process.alive?(GenServer.whereis(caller_name(id)))
    assert {:error, :unikernel_restart_refused} = VM.resume(record)
    stop_supervised!(Guest)
    assert {:error, :unikernel_restart_refused} = VM.revive(id)
    assert {:ok, ^record} = StateStore.get(id)
  end

  test "MCP passes bytes, budget and correlation and encodes the Lean reply", %{id: id} do
    parent = self()

    Application.put_env(:mjolnir, :unikernel_exchange, fn job ->
      send(parent, {:job, job})
      {:ok, 0, <<129, 1>>}
    end)

    args = %{
      "vm_id" => id,
      "program_b64" => Base.encode64(<<0, 255>>),
      "budget" => 5000,
      "id" => "0000000000000007"
    }

    assert {:ok, %{content: [%{"text" => text}]}, %{}} =
             Mjolnir.MCP.Server.handle_tool_call("deliver_message", args, %{})

    assert %{"transport_status" => 0, "reply_b64" => "gQE="} = Jason.decode!(text)
    assert_receive {:job, %{program: <<0, 255>>, budget: 5000, correlation_id: <<7::64>>}}

    assert {:ok, %{isError: true}, %{}} =
             Mjolnir.MCP.Server.handle_tool_call(
               "deliver_message",
               %{args | "program_b64" => "invalid!"},
               %{}
             )

    refute_receive {:job, _}
  end

  test "MCP rejects missing programs and invalid budgets before transport", %{id: id} do
    StateStore.put(Record.new(id, :running, spawn_config: %{"kind" => "unikernel"}))
    parent = self()

    Application.put_env(:mjolnir, :unikernel_exchange, fn _ ->
      send(parent, :unexpected_exchange)
      {:ok, 0, <<>>}
    end)

    for args <- [
          %{"vm_id" => id},
          %{"vm_id" => id, "program_b64" => "AA==", "budget" => 0},
          %{"vm_id" => id, "program_b64" => Base.encode64(:binary.copy(<<0>>, 1177))}
        ] do
      assert {:ok, %{isError: true}, %{}} =
               Mjolnir.MCP.Server.handle_tool_call("deliver_message", args, %{})
    end

    refute_receive :unexpected_exchange
  end

  test "agent health checks and healing do not probe a unikernel", %{id: id} do
    assert {:error, :unikernel_unsupported} = Mjolnir.Health.check(id)
    assert {:error, :unikernel_unsupported} = Mjolnir.Health.heal(id)
    assert :ok = Mjolnir.Health.Monitor.handle_check_result(id, {:error, :unikernel_unsupported})
  end

  defp caller_name(id), do: {:via, Registry, {Mjolnir.VMRegistry, id}}
  defp wait_unlocked(_id, 0), do: flunk("caller monitor did not release admission")

  defp wait_unlocked(id, n) do
    if GenServer.call(caller_name(id), :get_state).unikernel_busy do
      Process.sleep(1)
      wait_unlocked(id, n - 1)
    end
  end
end
