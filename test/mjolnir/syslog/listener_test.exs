defmodule Mjolnir.Syslog.ListenerTest do
  use ExUnit.Case, async: false

  alias Mjolnir.EventBus
  alias Mjolnir.Syslog.Listener
  alias Mjolnir.Syslog.Message
  alias Mjolnir.Vsock.Connection
  alias Mjolnir.Vsock.Protocol

  setup do
    case :pg.start_link(EventBus.pg_scope()) do
      {:ok, pid} -> on_exit(fn -> Process.exit(pid, :normal) end)
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "UDP bind" do
    test "unset udp_port does not bind" do
      name = unique_name("udp-off")
      {:ok, pid} = Listener.start_link(name: name, udp_port: nil, subscribe: false)
      on_exit(fn -> stop_listener(pid) end)

      assert Listener.udp_port(pid) == nil
      assert Listener.udp_port() == nil
    end

    test "udp_port: 0 binds loopback on an ephemeral port" do
      name = unique_name("udp-on")

      {:ok, pid} =
        Listener.start_link(
          name: name,
          udp_host: {127, 0, 0, 1},
          udp_port: 0,
          subscribe: false
        )

      on_exit(fn -> stop_listener(pid) end)

      port = Listener.udp_port(pid)
      assert is_integer(port) and port > 0
    end
  end

  describe "UDP ingest" do
    setup do
      {:ok, listener} = start_udp_listener()
      port = Listener.udp_port(listener)
      {:ok, sock} = :gen_udp.open(0, [:binary, {:active, false}])
      on_exit(fn -> :gen_udp.close(sock) end)
      %{listener: listener, port: port, sock: sock}
    end

    test "JSON MSG with schema publishes :app_log", %{port: port, sock: sock} do
      app = unique_id("myscape")
      EventBus.subscribe(app)

      json =
        Jason.encode!(%{
          "schema" => "myscape/1",
          "app" => app,
          "name" => app,
          "msg" => "hello from host",
          "level" => 30
        })

      :ok = :gen_udp.send(sock, {127, 0, 0, 1}, port, rfc3164(json, tag: app))

      assert_receive {:mjolnir_event, ^app, :app_log, record}, 1_000
      assert record["schema"] == "myscape/1"
      assert record["msg"] == "hello from host"
      assert record["source"] == "host"
    end

    test "non-JSON guest-style text publishes :vm_syslog", %{port: port, sock: sock} do
      host = unique_id("udphost")
      EventBus.subscribe(host)

      :ok = :gen_udp.send(sock, {127, 0, 0, 1}, port, rfc3164("oops", host: host, tag: "kernel"))

      assert_receive {:mjolnir_event, ^host, :vm_syslog, %Message{message: "oops"}}, 1_000
    end

    test "JSON without schema stays :vm_syslog", %{port: port, sock: sock} do
      host = unique_id("noschema")
      EventBus.subscribe(host)

      json = Jason.encode!(%{"msg" => "no schema", "level" => 30})
      :ok = :gen_udp.send(sock, {127, 0, 0, 1}, port, rfc3164(json, host: host))

      assert_receive {:mjolnir_event, ^host, :vm_syslog, %Message{}}, 1_000
      refute_receive {:mjolnir_event, _, :app_log, _}, 50
    end
  end

  describe "vsock channel 2" do
    test "Connection auto-registers Listener on ch2" do
      vm_id = unique_id("vm")
      path = start_fake_guest()
      {:ok, conn} = Connection.start_link(%{vm_id: vm_id, socket_path: path})
      on_exit(fn -> stop_proc(conn) end)
      _sock = wait_guest_ready()

      assert wait_registered(vm_id)
    end

    test ":vm_spawned with vsock_conn re-registers after stop" do
      vm_id = unique_id("vm")
      path = start_fake_guest()
      {:ok, conn} = Connection.start_link(%{vm_id: vm_id, socket_path: path})
      on_exit(fn -> stop_proc(conn) end)
      _sock = wait_guest_ready()

      assert wait_registered(vm_id)

      EventBus.publish(vm_id, :vm_stopped, %{})
      assert wait_unregistered(vm_id)

      EventBus.publish(vm_id, :vm_spawned, %{
        vsock_conn: conn,
        vsock_cid: Mjolnir.Vsock.cid(vm_id)
      })

      assert wait_registered(vm_id)
    end

    test "guest RFC 3164 text publishes :vm_syslog for that VM" do
      vm_id = unique_id("vm")
      EventBus.subscribe(vm_id)
      {_conn, sock} = start_vsock_vm(vm_id)

      frame = Protocol.encode(rfc3164("booted", host: vm_id, tag: "kernel") <> "\n", 2)
      :ok = :gen_tcp.send(sock, frame)

      assert_receive {:mjolnir_event, ^vm_id, :vm_syslog, %Message{message: "booted"}}, 1_000
    end

    test "guest JSON MSG with schema publishes :app_log (source guest)" do
      vm_id = unique_id("vm")
      app = unique_id("guestapp")
      EventBus.subscribe(app)
      EventBus.subscribe(vm_id)
      {_conn, sock} = start_vsock_vm(vm_id)

      json =
        Jason.encode!(%{
          "schema" => "myscape/1",
          "app" => app,
          "msg" => "from guest",
          "level" => 30
        })

      frame = Protocol.encode(rfc3164(json, host: vm_id, tag: app) <> "\n", 2)
      :ok = :gen_tcp.send(sock, frame)

      assert_receive {:mjolnir_event, ^app, :app_log, record}, 1_000
      assert record["source"] == "guest"
      assert record["msg"] == "from guest"
      refute_receive {:mjolnir_event, ^vm_id, :vm_syslog, _}, 50
    end

    test "identifies the sender when two VMs emit at once" do
      vm_a = unique_id("vma")
      vm_b = unique_id("vmb")
      EventBus.subscribe(vm_a)
      EventBus.subscribe(vm_b)

      {_conn_a, sock_a} = start_vsock_vm(vm_a)
      {_conn_b, sock_b} = start_vsock_vm(vm_b)

      :ok =
        :gen_tcp.send(
          sock_a,
          Protocol.encode(rfc3164("from-a", host: vm_a, tag: "t") <> "\n", 2)
        )

      :ok =
        :gen_tcp.send(
          sock_b,
          Protocol.encode(rfc3164("from-b", host: vm_b, tag: "t") <> "\n", 2)
        )

      assert_receive {:mjolnir_event, ^vm_a, :vm_syslog, %Message{message: "from-a"}}, 1_000
      assert_receive {:mjolnir_event, ^vm_b, :vm_syslog, %Message{message: "from-b"}}, 1_000
    end
  end

  describe "64 KiB max" do
    test "oversize vsock line is routed as malformed raw, not dropped" do
      vm_id = unique_id("big")
      EventBus.subscribe(vm_id)

      huge = :binary.copy("x", 66_000)
      send(Listener, {:syslog_data, vm_id, 3, huge})

      assert_receive {:mjolnir_event, ^vm_id, :vm_syslog, %Message{raw: raw}}, 1_000
      assert byte_size(raw) > 65_536
    end

    test "a complete line at the limit is parsed, not treated as malformed" do
      vm_id = unique_id("fit")
      EventBus.subscribe(vm_id)

      # Header ~40 bytes; pad the MSG so the whole line sits under 64 KiB.
      pad = :binary.copy("a", 65_000)
      line = rfc3164(pad, host: vm_id, tag: "t")
      assert byte_size(line) <= 65_536

      send(Listener, {:syslog_data, vm_id, 3, line <> "\n"})

      assert_receive {:mjolnir_event, ^vm_id, :vm_syslog, %Message{message: ^pad}}, 1_000
    end

    test "oversize UDP datagram is malformed raw, not dropped" do
      {:ok, listener} = start_udp_listener()
      EventBus.subscribe("host")

      huge = :binary.copy("y", 66_000)
      socket = :sys.get_state(listener).udp_socket
      send(listener, {:udp, socket, {127, 0, 0, 1}, 1, huge})

      assert_receive {:mjolnir_event, "host", :vm_syslog, %Message{raw: raw}}, 1_000
      assert byte_size(raw) > 65_536
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp unique_name(prefix) do
    :"syslog-#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp rfc3164(msg, opts) do
    pri = Keyword.get(opts, :pri, 13)
    host = Keyword.get(opts, :host, "testhost")
    tag = Keyword.get(opts, :tag, "app")
    "<#{pri}>Jan  1 00:00:00 #{host} #{tag}: #{msg}"
  end

  defp start_udp_listener do
    name = unique_name("udp")

    {:ok, pid} =
      Listener.start_link(
        name: name,
        udp_host: {127, 0, 0, 1},
        udp_port: 0,
        subscribe: false
      )

    on_exit(fn -> stop_listener(pid) end)
    {:ok, pid}
  end

  defp start_vsock_vm(vm_id) do
    path = start_fake_guest()
    {:ok, conn} = Connection.start_link(%{vm_id: vm_id, socket_path: path})
    on_exit(fn -> stop_proc(conn) end)
    sock = wait_guest_ready()
    assert wait_registered(vm_id)
    {conn, sock}
  end

  defp start_fake_guest do
    path = Path.join(System.tmp_dir!(), "mj-sl-#{System.unique_integer([:positive])}.sock")
    File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        {:ifaddr, {:local, path}},
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true
      ])

    parent = self()

    server =
      spawn(fn ->
        case :gen_tcp.accept(listen, 5_000) do
          {:ok, sock} ->
            {:ok, _connect} = :gen_tcp.recv(sock, 0, 5_000)
            :ok = :gen_tcp.send(sock, "OK 1\n")
            send(parent, {:guest_ready, sock})
            Process.sleep(:infinity)

          _ ->
            :ok
        end
      end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listen)
      File.rm(path)
    end)

    path
  end

  defp wait_guest_ready do
    assert_receive {:guest_ready, sock}, 2_000
    sock
  end

  defp wait_registered(vm_id, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_registered(vm_id, deadline, true)
  end

  defp wait_unregistered(vm_id, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_registered(vm_id, deadline, false)
  end

  defp do_wait_registered(vm_id, deadline, want) do
    if Listener.registered?(vm_id) == want do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("Listener registered?(#{vm_id}) never became #{want}")
      else
        Process.sleep(10)
        do_wait_registered(vm_id, deadline, want)
      end
    end
  end

  defp stop_listener(pid) do
    if is_pid(pid) and Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end

  defp stop_proc(pid) do
    if is_pid(pid) and Process.alive?(pid) do
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end
  end
end
