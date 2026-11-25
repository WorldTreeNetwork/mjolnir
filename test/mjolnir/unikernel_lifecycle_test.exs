defmodule Mjolnir.UnikernelLifecycleTest do
  use ExUnit.Case, async: false
  alias Mjolnir.{VM, StateStore}
  alias Mjolnir.StateStore.Record

  @entity "6mUFfKo4KPLqjeAVqthhCZB82jgWjbo3RPJAAWdTynq1"

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
             entity: "6mUFfKo4KPLqjeAVqthhCZB82jgWjbo3RPJAAWdTynq1",
             allow: []
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

  test "a guest that presented another name poisons later attempts without another exchange",
       %{id: id} do
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

    assert %{"transport_status" => 0, "reply_b64" => "gQE=", "outcome" => "budget"} =
             Jason.decode!(text)

    assert_receive {:job, %{program: <<0, 255>>, budget: 5000, correlation_id: <<7::64>>}}

    assert {:ok, %{isError: true}, %{}} =
             Mjolnir.MCP.Server.handle_tool_call(
               "deliver_message",
               %{args | "program_b64" => "invalid!"},
               %{}
             )

    refute_receive {:job, _}
  end

  test "HTTP names the reply's outcome; a space reply is a status-0 answer", %{id: id} do
    import Plug.Test
    import Plug.Conn
    StateStore.put(Record.new(id, :running, spawn_config: %{"kind" => "unikernel"}))
    auth = Application.get_env(:mjolnir, :auth, [])
    Application.put_env(:mjolnir, :auth, bypass_localhost: true)
    on_exit(fn -> Application.put_env(:mjolnir, :auth, auth) end)

    post = fn reply ->
      Application.put_env(:mjolnir, :unikernel_exchange, fn _ -> reply end)

      conn(:post, "/api/vms/#{id}/messages", Jason.encode!(%{program_b64: "AP8=", budget: 9}))
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("content-type", "application/json")
      |> Mjolnir.API.Router.call(Mjolnir.API.Router.init([]))
    end

    conn = post.({:ok, 0, <<0x81, 7>>})
    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) ==
             %{"ok" => true, "transport_status" => 0, "reply_b64" => "gQc=", "outcome" => "space"}

    conn = post.({:ok, 2, ""})
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "reply_too_large" and not Map.has_key?(body, "outcome")
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

  describe "the host QUIC client's exit status" do
    # Drives Exchange.port/1, the production path, with a stub client that
    # records its arguments and exits with the status the real client
    # (native/reflect_quic/host.zig) gives for each outcome.
    setup do
      dir = Path.join(System.tmp_dir!(), "reflect-stub-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      old_bin = Application.get_env(:mjolnir, :reflect_quic_client)
      old_key = Application.get_env(:mjolnir, :reflect_client_key)
      Application.delete_env(:mjolnir, :unikernel_exchange)
      Application.put_env(:mjolnir, :reflect_client_key, Path.join(dir, "reflect-client.key"))

      on_exit(fn ->
        if old_bin,
          do: Application.put_env(:mjolnir, :reflect_quic_client, old_bin),
          else: Application.delete_env(:mjolnir, :reflect_quic_client)

        if old_key,
          do: Application.put_env(:mjolnir, :reflect_client_key, old_key),
          else: Application.delete_env(:mjolnir, :reflect_client_key)

        File.rm_rf(dir)
      end)

      %{dir: dir}
    end

    defp stub_client(dir, status) do
      bin = Path.join(dir, "client-#{status}")
      File.write!(bin, "#!/bin/sh\necho \"$@\" > #{dir}/args\nexit #{status}\n")
      File.chmod!(bin, 0o755)
      Application.put_env(:mjolnir, :reflect_quic_client, bin)
    end

    test "silence until the client's deadline is unikernel_timeout and releases the guest",
         %{id: id, dir: dir} do
      # host.zig returns 4 when 60 s pass with no reply frame.
      stub_client(dir, 4)

      assert {:error, :unikernel_timeout} =
               VM.unikernel_message(id, <<1>>, 5000, "000000000000000a")

      assert ["10.0.0.2", "30001", "5000", key, @entity, _path, "000000000000000A"] =
               dir |> Path.join("args") |> File.read!() |> String.split()

      # This host's client key, made on first use: a 0600 file of 32 bytes.
      assert key == Path.join(dir, "reflect-client.key")
      assert byte_size(File.read!(key)) == 32
      assert File.stat!(key).mode |> Bitwise.band(0o777) == 0o600
      refute GenServer.call(caller_name(id), :get_state).unikernel_busy

      assert {:ok, %{isError: true, content: [%{"text" => text}]}, %{}} =
               Mjolnir.MCP.Server.handle_tool_call(
                 "deliver_message",
                 %{"vm_id" => id, "program_b64" => "AQ=="},
                 %{}
               )

      assert text =~ "unikernel_timeout"
    end

    test "statuses 3, 5, 6 and 7 are the refused guest, transport statuses 2 and 3, and no answer",
         %{dir: dir} do
      key = Path.join(dir, "other.key")
      File.write!(key, :binary.copy(<<7>>, 32))

      job = %{
        program: <<1>>,
        budget: 5000,
        guest_ip: "10.0.0.2",
        quic_port: 30001,
        entity: @entity,
        client_key: key,
        correlation_id: <<1::64>>
      }

      stub_client(dir, 3)
      assert {:error, :peer_key_refused} = Mjolnir.Unikernel.Exchange.port(job)
      stub_client(dir, 5)
      assert {:ok, 2, ""} = Mjolnir.Unikernel.Exchange.port(job)
      stub_client(dir, 6)
      assert {:ok, 3, ""} = Mjolnir.Unikernel.Exchange.port(job)
      # A flight given up with no answer: the guest does not allow this key.
      stub_client(dir, 7)
      assert {:error, :unikernel_timeout} = Mjolnir.Unikernel.Exchange.port(job)

      # The job's own key file is the one passed.
      assert [_, _, _, ^key, @entity, _, _] =
               dir |> Path.join("args") |> File.read!() |> String.split()

      assert {:error, :entity_required} =
               Mjolnir.Unikernel.Exchange.port(Map.delete(job, :entity))
    end
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
