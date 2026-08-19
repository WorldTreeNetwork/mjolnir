defmodule Mjolnir.Vsock.ProtocolTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Vsock.Protocol

  describe "encode/2 with channel multiplexing" do
    test "encodes JSON message on channel 0" do
      message = %{"type" => "ping", "id" => "test-123"}
      encoded = Protocol.encode(message, 0)

      # Check format: 1 byte channel + 4 bytes length + JSON payload
      <<channel::8, length::big-32, payload::binary>> = encoded
      assert channel == 0
      assert byte_size(payload) == length
      assert Jason.decode!(payload) == message
    end

    test "encodes JSON message on default channel (0)" do
      message = %{"type" => "exec", "command" => "ls"}
      encoded = Protocol.encode(message)

      <<channel::8, _length::big-32, _payload::binary>> = encoded
      assert channel == 0
    end

    test "encodes binary data on channel 5" do
      data = "Hello, PTY!"
      encoded = Protocol.encode(data, 5)

      <<channel::8, length::big-32, payload::binary>> = encoded
      assert channel == 5
      assert length == byte_size(data)
      assert payload == data
    end

    test "encodes binary data on channel 255" do
      data = <<1, 2, 3, 4, 5>>
      encoded = Protocol.encode(data, 255)

      <<channel::8, length::big-32, payload::binary>> = encoded
      assert channel == 255
      assert length == byte_size(data)
      assert payload == data
    end

    test "handles empty binary data" do
      encoded = Protocol.encode(<<>>, 10)

      <<channel::8, length::big-32, payload::binary>> = encoded
      assert channel == 10
      assert length == 0
      assert payload == <<>>
    end

    test "handles large binary payloads" do
      data = :crypto.strong_rand_bytes(10_000)
      encoded = Protocol.encode(data, 42)

      <<channel::8, length::big-32, payload::binary>> = encoded
      assert channel == 42
      assert length == 10_000
      assert payload == data
    end
  end

  describe "decode_frame/1" do
    test "decodes complete frame on channel 0" do
      message = %{"type" => "pong"}
      encoded = Protocol.encode(message, 0)

      assert {:ok, channel, payload, rest} = Protocol.decode_frame(encoded)
      assert channel == 0
      assert Jason.decode!(payload) == message
      assert rest == <<>>
    end

    test "decodes complete frame on channel 7" do
      data = "test data"
      encoded = Protocol.encode(data, 7)

      assert {:ok, channel, payload, rest} = Protocol.decode_frame(encoded)
      assert channel == 7
      assert payload == data
      assert rest == <<>>
    end

    test "returns incomplete for partial header" do
      partial = <<5, 0, 0>>
      assert {:incomplete, ^partial} = Protocol.decode_frame(partial)
    end

    test "returns incomplete when payload is incomplete" do
      # Channel 3, length 100, but only 50 bytes of payload
      partial = <<3, 0, 0, 0, 100>> <> :crypto.strong_rand_bytes(50)
      assert {:incomplete, ^partial} = Protocol.decode_frame(partial)
    end

    test "decodes frame and returns remaining data" do
      frame1 = Protocol.encode(%{"type" => "ping"}, 0)
      frame2 = Protocol.encode("data", 1)
      buffer = frame1 <> frame2

      assert {:ok, 0, payload1, rest1} = Protocol.decode_frame(buffer)
      assert Jason.decode!(payload1) == %{"type" => "ping"}

      assert {:ok, 1, payload2, rest2} = Protocol.decode_frame(rest1)
      assert payload2 == "data"
      assert rest2 == <<>>
    end

    test "handles empty buffer" do
      assert {:incomplete, <<>>} = Protocol.decode_frame(<<>>)
    end
  end

  describe "PTY control message builders" do
    test "pty_open_request/3 builds correct message" do
      request = Protocol.pty_open_request(30, 120)

      assert request["type"] == "pty_open"
      assert request["rows"] == 30
      assert request["cols"] == 120
      assert is_binary(request["id"])
    end

    test "pty_open_request/3 uses defaults" do
      request = Protocol.pty_open_request()

      assert request["rows"] == 24
      assert request["cols"] == 80
    end

    test "pty_open_request/3 accepts custom request_id" do
      request = Protocol.pty_open_request(24, 80, "custom-id")

      assert request["id"] == "custom-id"
    end

    test "pty_open_request/4 carries a tmux session name when given" do
      request = Protocol.pty_open_request(24, 80, "custom-id", "main")

      assert request["session"] == "main"
    end

    test "pty_open_request/4 omits the session key entirely when nil" do
      # Older guest agents reject unknown keys, and a private shell is the
      # historical behaviour — so nil must produce a byte-identical message,
      # not `"session" => null`.
      assert Protocol.pty_open_request(24, 80, "custom-id") ==
               Protocol.pty_open_request(24, 80, "custom-id", nil)

      refute Map.has_key?(Protocol.pty_open_request(24, 80, "id", nil), "session")
    end

    test "pty_resize_request/3 builds correct message" do
      request = Protocol.pty_resize_request(5, 40, 100)

      assert request["type"] == "pty_resize"
      assert request["channel"] == 5
      assert request["rows"] == 40
      assert request["cols"] == 100
    end

    test "pty_close_request/1 builds correct message" do
      request = Protocol.pty_close_request(7)

      assert request["type"] == "pty_close"
      assert request["channel"] == 7
    end
  end

  describe "agent protocol message builders" do
    test "spawn_sub_agent_request/2 builds correct message" do
      opts = %{"image" => "alpine", "command" => "/bin/sh"}
      request = Protocol.spawn_sub_agent_request(opts)

      assert request["type"] == "spawn_sub_agent"
      assert request["opts"] == opts
      assert is_binary(request["id"])
    end

    test "spawn_sub_agent_request/2 accepts custom request_id" do
      request = Protocol.spawn_sub_agent_request(%{}, "custom-id")

      assert request["id"] == "custom-id"
    end

    test "snapshot_self_request/2 builds correct message" do
      request = Protocol.snapshot_self_request("my-snapshot")

      assert request["type"] == "snapshot_self"
      assert request["name"] == "my-snapshot"
      assert is_binary(request["id"])
    end

    test "snapshot_self_request/2 accepts custom request_id" do
      request = Protocol.snapshot_self_request("snap", "custom-id")

      assert request["id"] == "custom-id"
    end

    test "emit_event_request/3 builds correct message" do
      request = Protocol.emit_event_request("user_action", %{"key" => "value"})

      assert request["type"] == "emit_event"
      assert request["event"] == "user_action"
      assert request["payload"] == %{"key" => "value"}
      assert is_binary(request["id"])
    end

    test "emit_event_request/3 accepts custom request_id" do
      request = Protocol.emit_event_request("event", %{}, "custom-id")

      assert request["id"] == "custom-id"
    end
  end

  describe "existing message builders" do
    test "exec_request/2 still works" do
      request = Protocol.exec_request("ls -la")

      assert request["type"] == "exec"
      assert request["command"] == "ls -la"
      assert is_binary(request["id"])
    end

    test "ping/0 still works" do
      ping = Protocol.ping()
      assert ping["type"] == "ping"
    end

    test "configure_network_request/2 still works" do
      request = Protocol.configure_network_request("10.0.0.5")

      assert request["type"] == "configure_network"
      assert request["ip"] == "10.0.0.5"
      assert is_binary(request["id"])
    end

    test "configure_ssh_request/2 still works" do
      keys = "ssh-rsa AAAA..."
      request = Protocol.configure_ssh_request(keys)

      assert request["type"] == "configure_ssh"
      assert request["authorized_keys"] == keys
      assert is_binary(request["id"])
    end

    test "configure_identity_request/3 still works" do
      request = Protocol.configure_identity_request("vm-123", "http://api.example.com")

      assert request["type"] == "configure_identity"
      assert request["vm_id"] == "vm-123"
      assert request["api_url"] == "http://api.example.com"
      refute Map.has_key?(request, "blob_door_url")
      assert is_binary(request["id"])
    end

    test "configure_identity_request/4 includes blob_door_url" do
      request =
        Protocol.configure_identity_request(
          "vm-123",
          "http://10.200.0.1:4000",
          "http://10.200.0.1:7222"
        )

      assert request["blob_door_url"] == "http://10.200.0.1:7222"
    end

    test "get_iroh_status_request/1 still works" do
      request = Protocol.get_iroh_status_request()

      assert request["type"] == "get_iroh_status"
      assert is_binary(request["id"])
    end

    test "configure_iroh_request/2 still works" do
      request = Protocol.configure_iroh_request(true)

      assert request["type"] == "configure_iroh"
      assert request["enabled"] == true
      assert is_binary(request["id"])
    end
  end

  describe "parse_iroh_ready/1" do
    test "parses valid iroh_ready message" do
      msg = %{
        "type" => "iroh_ready",
        "node_id" => "abc123",
        "ticket" => "ticket456",
        "generated_key" => false
      }

      assert {:ok, result} = Protocol.parse_iroh_ready(msg)
      assert result.node_id == "abc123"
      assert result.ticket == "ticket456"
      assert result.generated_key == false
    end

    test "defaults generated_key to true" do
      msg = %{
        "type" => "iroh_ready",
        "node_id" => "abc123",
        "ticket" => "ticket456"
      }

      assert {:ok, result} = Protocol.parse_iroh_ready(msg)
      assert result.generated_key == true
    end

    test "returns error for invalid message" do
      assert {:error, :invalid_iroh_ready} = Protocol.parse_iroh_ready(%{})
    end
  end

  describe "multiple frames in buffer" do
    test "processes multiple complete frames" do
      frame1 = Protocol.encode(%{"type" => "ping"}, 0)
      frame2 = Protocol.encode("hello", 5)
      frame3 = Protocol.encode(%{"type" => "pong"}, 0)
      buffer = frame1 <> frame2 <> frame3

      assert {:ok, 0, payload1, rest1} = Protocol.decode_frame(buffer)
      assert Jason.decode!(payload1) == %{"type" => "ping"}

      assert {:ok, 5, payload2, rest2} = Protocol.decode_frame(rest1)
      assert payload2 == "hello"

      assert {:ok, 0, payload3, rest3} = Protocol.decode_frame(rest2)
      assert Jason.decode!(payload3) == %{"type" => "pong"}

      assert rest3 == <<>>
    end

    test "handles partial frame at end of buffer" do
      complete = Protocol.encode(%{"type" => "ping"}, 0)
      partial = <<7, 0, 0, 0, 50, "incomplete"::binary>>
      buffer = complete <> partial

      assert {:ok, 0, payload, rest} = Protocol.decode_frame(buffer)
      assert Jason.decode!(payload) == %{"type" => "ping"}

      assert {:incomplete, ^partial} = Protocol.decode_frame(rest)
    end
  end

  describe "read_json_response/2 (mjolnir-pry)" do
    # A raw listen/accept pair stands in for the guest side of the vsock UDS:
    # the test writes frames onto the accepted socket in whatever order it
    # likes, and calls Protocol.read_json_response/2 on the client socket —
    # exactly the pattern vm.ex's vsock_request/try_ping_agent use.
    setup do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      # gen_tcp sockets are owned by the process that opens them and close
      # when that process exits — so both ends must be connected/accepted
      # from a process that outlives the setup (here: hand ownership back to
      # the test process before the connecting Task exits).
      test_pid = self()

      task =
        Task.async(fn ->
          {:ok, sock} =
            :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw])

          :ok = :gen_tcp.controlling_process(sock, test_pid)
          sock
        end)

      {:ok, server} = :gen_tcp.accept(listen)
      client = Task.await(task)

      on_exit(fn ->
        :gen_tcp.close(client)
        :gen_tcp.close(server)
        :gen_tcp.close(listen)
      end)

      {:ok, client: client, server: server}
    end

    test "returns the channel-0 JSON response when it arrives cleanly", %{
      client: client,
      server: server
    } do
      :ok = :gen_tcp.send(server, Protocol.encode(%{"type" => "pong"}, 0))

      assert {:ok, %{"type" => "pong"}} = Protocol.read_json_response(client, 1_000)
    end

    test "skips a real RFC 3164 syslog line on channel 2 and finds the pong behind it",
         %{client: client, server: server} do
      # Exact payload from mjolnir-pry (CI run 14, 2026-08-12 16:57): a guest
      # syslog line racing a freshly-opened connection's pong response. This
      # is the literal reproduction of the bug, not a synthetic stand-in.
      syslog_line =
        "<30>Aug 12 16:57:15 dbus-daemon[776]: [system] Successfully activated service 'org.freedesktop.systemd1'\n"

      :ok = :gen_tcp.send(server, Protocol.encode(syslog_line, 2))
      :ok = :gen_tcp.send(server, Protocol.encode(%{"type" => "pong"}, 0))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{"type" => "pong"}} = Protocol.read_json_response(client, 1_000)
        end)

      assert log =~ "Skipping non-control vsock frame"
      assert log =~ "channel 2"
      assert log =~ "dbus-daemon"
    end

    test "skips a channel-0 frame that isn't valid JSON instead of failing", %{
      client: client,
      server: server
    } do
      :ok = :gen_tcp.send(server, Protocol.encode("not json at all", 0))
      :ok = :gen_tcp.send(server, Protocol.encode(%{"type" => "pong"}, 0))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{"type" => "pong"}} = Protocol.read_json_response(client, 1_000)
        end)

      assert log =~ "Skipping non-JSON control-channel frame"
    end

    test "times out rather than hanging forever when no response ever arrives", %{
      client: client
    } do
      assert {:error, :timeout} = Protocol.read_json_response(client, 100)
    end
  end

  describe "inject_identity_request/2 (mjolnir-1pe)" do
    test "builds entries for buzz.env without extra host fields" do
      identity = %{
        private_key_nsec: "nsec1test",
        relay_url: "wss://relay.test"
      }

      msg = Protocol.inject_identity_request(identity, request_id: "id-1")
      assert msg["type"] == "inject_identity"
      assert msg["id"] == "id-1"

      assert msg["entries"] == %{
               "BUZZ_PRIVATE_KEY" => "nsec1test",
               "BUZZ_RELAY_URL" => "wss://relay.test"
             }

      refute Map.has_key?(msg, "passphrase")
    end

    test "round-trips through encode on channel 0" do
      msg =
        Protocol.inject_identity_request(%{
          private_key_nsec: "nsec1test",
          relay_url: "wss://relay.test"
        })

      encoded = Protocol.encode(msg, 0)
      <<channel::8, length::big-32, payload::binary>> = encoded
      assert channel == 0
      assert byte_size(payload) == length
      assert Jason.decode!(payload) == msg
    end
  end

  describe "inject_secrets_request/2 (managed secrets)" do
    test "builds a minimal request with just a passphrase" do
      msg = Protocol.inject_secrets_request("s3cret")

      assert msg["type"] == "inject_secrets"
      assert msg["passphrase"] == "s3cret"
      assert is_binary(msg["id"])
      # optional fields are omitted (guest serde defaults handle absence)
      refute Map.has_key?(msg, "init_size_mb")
      refute Map.has_key?(msg, "entries")
    end

    test "includes init_size_mb and entries when provided" do
      msg =
        Protocol.inject_secrets_request("pw",
          init_size_mb: 64,
          entries: %{"SMTP_PASS" => "abc"}
        )

      assert msg["init_size_mb"] == 64
      assert msg["entries"] == %{"SMTP_PASS" => "abc"}
    end

    test "accepts an explicit request_id" do
      msg = Protocol.inject_secrets_request("pw", request_id: "req-1")
      assert msg["id"] == "req-1"
    end

    test "round-trips through encode on channel 0" do
      msg = Protocol.inject_secrets_request("pw", init_size_mb: 32)
      encoded = Protocol.encode(msg, 0)

      <<channel::8, length::big-32, payload::binary>> = encoded
      assert channel == 0
      assert byte_size(payload) == length
      assert Jason.decode!(payload) == msg
    end
  end

  describe "suspend_secrets_request/1 (mjolnir-k8y.3)" do
    test "builds a request with a generated id" do
      msg = Protocol.suspend_secrets_request()
      assert msg["type"] == "suspend_secrets"
      assert is_binary(msg["id"])
      refute Map.has_key?(msg, "passphrase")
    end

    test "accepts an explicit request_id" do
      msg = Protocol.suspend_secrets_request(request_id: "req-s")
      assert msg["id"] == "req-s"
    end
  end

  describe "resume_secrets_request/2 (mjolnir-k8y.3)" do
    test "carries the passphrase" do
      msg = Protocol.resume_secrets_request("s3cret")
      assert msg["type"] == "resume_secrets"
      assert msg["passphrase"] == "s3cret"
      assert is_binary(msg["id"])
    end

    test "round-trips through encode on channel 0" do
      msg = Protocol.resume_secrets_request("pw", request_id: "req-r")
      encoded = Protocol.encode(msg, 0)
      <<channel::8, length::big-32, payload::binary>> = encoded
      assert channel == 0
      assert byte_size(payload) == length
      assert Jason.decode!(payload) == msg
    end
  end
end
