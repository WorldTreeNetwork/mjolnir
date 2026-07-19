defmodule Mjolnir.Vsock.ConnectionTest do
  # Exercises the bounded request/reply timeout added in mjolnir-8ie: a wedged
  # guest must no longer pin the caller forever. Uses a fake UNIX-domain socket
  # server that stands in for Cloud Hypervisor's vsock proxy + guest agent.
  use ExUnit.Case, async: false

  alias Mjolnir.Vsock.Connection
  alias Mjolnir.Vsock.Protocol

  # Boot a fake guest listening on a fresh UDS. `mode` controls how it answers
  # after the "CONNECT <port>\n" / "OK\n" handshake:
  #   :silent    — never replies (drives the timeout path)
  #   :late      — replies to the FIRST request ~300ms late, then promptly
  defp start_fake_guest(mode) do
    path = Path.join(System.tmp_dir!(), "mj-vsock-#{System.unique_integer([:positive])}.sock")
    File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        {:ifaddr, {:local, path}},
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true
      ])

    # Unlinked: a fake-server crash (e.g. socket closed at test teardown) must
    # never take the test process down with it.
    _server =
      spawn(fn ->
        case :gen_tcp.accept(listen, 5_000) do
          {:ok, sock} ->
            {:ok, _connect} = :gen_tcp.recv(sock, 0, 5_000)
            :ok = :gen_tcp.send(sock, "OK 1\n")
            serve(sock, mode)

          _ ->
            :ok
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listen)
      File.rm(path)
    end)

    path
  end

  defp serve(_sock, :silent), do: Process.sleep(2_000)

  defp serve(sock, :late) do
    case recv_request(sock) do
      {:msg, %{"id" => id}} ->
        Process.sleep(300)
        reply_exec(sock, id, "late")
        serve(sock, :immediate)

      :closed ->
        :ok
    end
  end

  defp serve(sock, :immediate) do
    case recv_request(sock) do
      {:msg, %{"id" => id, "type" => "ping"}} ->
        :gen_tcp.send(sock, Protocol.encode(%{"type" => "pong", "id" => id}, 0))
        serve(sock, :immediate)

      {:msg, %{"id" => id}} ->
        reply_exec(sock, id, "ok")
        serve(sock, :immediate)

      :closed ->
        :ok
    end
  end

  defp reply_exec(sock, id, stdout) do
    frame =
      Protocol.encode(
        %{"type" => "exec_response", "id" => id, "exit_code" => 0, "stdout" => stdout},
        0
      )

    :gen_tcp.send(sock, frame)
  end

  # Accumulate bytes until a full channel-0 control frame decodes.
  defp recv_request(sock, buf \\ <<>>) do
    case Protocol.decode_frame(buf) do
      {:ok, 0, payload, _rest} ->
        {:msg, Jason.decode!(payload)}

      _ ->
        case :gen_tcp.recv(sock, 0, 5_000) do
          {:ok, data} -> recv_request(sock, buf <> data)
          {:error, _} -> :closed
        end
    end
  end

  test "exec returns {:error, :timeout} when the guest never replies" do
    path = start_fake_guest(:silent)
    {:ok, conn} = Connection.start_link(%{vm_id: "vm-timeout", socket_path: path})

    assert {:error, :timeout} = Connection.exec(conn, "sleep 999", 150)
    # The connection survives the timeout — only the one request was abandoned.
    assert Process.alive?(conn)
  end

  test "ping returns {:error, :timeout} when the guest never pongs" do
    path = start_fake_guest(:silent)
    {:ok, conn} = Connection.start_link(%{vm_id: "vm-ping", socket_path: path})

    assert {:error, :timeout} = Connection.ping(conn, 150)
    assert Process.alive?(conn)
  end

  test "a late guest reply after a timeout is discarded safely" do
    path = start_fake_guest(:late)
    {:ok, conn} = Connection.start_link(%{vm_id: "vm-late", socket_path: path})

    # First exec times out at 150ms; the guest's reply lands ~300ms in.
    assert {:error, :timeout} = Connection.exec(conn, "slow", 150)

    # Let the late reply arrive and be processed as an unknown-request no-op.
    Process.sleep(350)
    assert Process.alive?(conn)

    # The connection is still fully usable: the next request gets its reply.
    assert {:ok, "ok"} = Connection.exec(conn, "echo ok", 2_000)
  end
end
