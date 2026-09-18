defmodule Mjolnir.Vsock.Protocol do
  @moduledoc """
  Wire protocol for host↔guest communication over vsock.

  Message format (with channel multiplexing):
  - 1 byte: channel ID (0 = JSON control, 1-255 = binary PTY streams)
  - 4 bytes: payload length (big-endian uint32)
  - N bytes: payload (JSON for channel 0, binary for others)

  Channel 0 message types:
  - exec_request/exec_response: Command execution
  - ping/pong: Connectivity check
  - configure_network/configure_ssh/configure_identity: Boot-time config
  - configure_iroh/get_iroh_status: Iroh networking control
  - pty_open/pty_opened/pty_resize/pty_close: PTY lifecycle
  - spawn_sub_agent/snapshot_self/emit_event: Agent protocol
  """

  require Logger

  @doc """
  Encode a message for transmission with channel multiplexing.

  For maps (JSON control messages), encodes to JSON on the specified channel.
  For binary data, sends raw binary on the specified channel.
  """
  def encode(message, channel \\ 0)

  def encode(message, channel) when is_map(message) do
    json = Jason.encode!(message)
    length = byte_size(json)
    <<channel::8, length::big-32, json::binary>>
  end

  def encode(data, channel) when is_binary(data) do
    length = byte_size(data)
    <<channel::8, length::big-32, data::binary>>
  end

  @doc """
  Decode a frame from the wire, returning channel, payload, and remaining buffer.

  Returns:
  - `{:ok, channel, payload, rest}` - Successfully decoded a complete frame
  - `{:incomplete, buffer}` - Need more data to complete frame
  """
  # Max frame size matches the 64KB limit enforced by the Rust guest agent.
  # Prevents memory exhaustion from malformed frames.
  @max_frame_size 65_536

  def decode_frame(<<channel::8, length::big-32, rest::binary>>)
      when length <= @max_frame_size and byte_size(rest) >= length do
    <<payload::binary-size(length), remaining::binary>> = rest
    {:ok, channel, payload, remaining}
  end

  def decode_frame(<<_channel::8, length::big-32, _rest::binary>>)
      when length > @max_frame_size do
    {:error, :frame_too_large}
  end

  def decode_frame(buffer), do: {:incomplete, buffer}

  # Bytes kept when logging the offending frame of a skipped/unparseable
  # control message — enough to identify it, small enough to never flood logs.
  @log_prefix_bytes 200

  @doc """
  Read a single channel-0 (JSON control) response from a raw, unframed-buffer
  vsock socket, skipping anything that is not a decodable control message
  instead of failing.

  Intended for the short-lived, single-shot vsock connections used during VM
  boot (ping polling, configure_* requests) — as opposed to the persistent
  `Mjolnir.Vsock.Connection`, which already demultiplexes channels itself.
  Those short-lived connections read "the next frame" off the wire and used
  to assume it was always their own channel-0 reply.

  It isn't always. Every fresh vsock connection makes the guest agent spawn a
  brand-new syslog forwarder (native/mjolnir_guest_agent/src/vsock.rs,
  `handle_vsock_connection`) that immediately starts draining `/dev/log`. On
  a freshly-booted guest that backlog can include boot noise (dbus/systemd
  activation lines) framed on channel 2, and it can win the race against the
  guest formatting and enqueueing the actual channel-0 response — landing on
  the wire first. Reading "whatever arrives next" and handing it straight to
  `Jason.decode` then fails on raw syslog text (mjolnir-pry).

  This loops — bounded by `timeout` in total — logging a warning (with a
  bounded byte prefix) and skipping any non-channel-0 frame, and any
  channel-0 frame that doesn't decode as JSON, until it finds one that does
  or time runs out.
  """
  @spec read_json_response(:gen_tcp.socket(), timeout()) :: {:ok, map()} | {:error, term()}
  def read_json_response(sock, timeout) when is_integer(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_read_json_response(sock, deadline)
  end

  defp do_read_json_response(sock, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      with {:ok, <<channel::8, length::big-32>>} <- :gen_tcp.recv(sock, 5, remaining),
           body_timeout = max(deadline - System.monotonic_time(:millisecond), 0),
           {:ok, body} <- :gen_tcp.recv(sock, length, body_timeout) do
        handle_response_frame(sock, deadline, channel, body)
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp handle_response_frame(sock, deadline, channel, body) when channel != 0 do
    Logger.warning(
      "Skipping non-control vsock frame while awaiting response " <>
        "(channel #{channel}, #{byte_size(body)} bytes): #{inspect(log_prefix(body))}"
    )

    do_read_json_response(sock, deadline)
  end

  defp handle_response_frame(sock, deadline, 0, body) do
    case Jason.decode(body) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, reason} ->
        Logger.warning(
          "Skipping non-JSON control-channel frame: #{inspect(reason)}, prefix: " <>
            inspect(log_prefix(body))
        )

        do_read_json_response(sock, deadline)
    end
  end

  defp log_prefix(body), do: binary_part(body, 0, min(byte_size(body), @log_prefix_bytes))

  @doc """
  Build an exec request message.
  """
  def exec_request(command, request_id \\ nil) do
    %{
      "type" => "exec",
      "id" => request_id || UUID.uuid4(),
      "command" => command
    }
  end

  @doc """
  Build a ping message.
  """
  def ping, do: %{"type" => "ping"}

  @doc """
  Build a configure_network request message.
  Guest agent will configure eth0 with the given IP.
  """
  def configure_network_request(ip, request_id \\ nil) do
    %{
      "type" => "configure_network",
      "id" => request_id || UUID.uuid4(),
      "ip" => ip
    }
  end

  @doc """
  Build a configure_ssh request message.
  Guest agent will write the given authorized_keys to /root/.ssh/authorized_keys.
  """
  def configure_ssh_request(authorized_keys, request_id \\ nil) do
    %{
      "type" => "configure_ssh",
      "id" => request_id || UUID.uuid4(),
      "authorized_keys" => authorized_keys
    }
  end

  @doc """
  Build a configure_identity request message.
  Guest agent writes /etc/mjolnir/vm.json with vm_id, api_url, and
  optional blob_door_url (overlay origin of mjolnir-blob-door).
  """
  def configure_identity_request(vm_id, api_url, blob_door_url \\ nil, request_id \\ nil) do
    base = %{
      "type" => "configure_identity",
      "id" => request_id || UUID.uuid4(),
      "vm_id" => vm_id,
      "api_url" => api_url
    }

    case blob_door_url do
      url when is_binary(url) and url != "" -> Map.put(base, "blob_door_url", url)
      _ -> base
    end
  end

  @doc """
  Build a get_iroh_status request message.
  Guest agent will return the current Iroh status.
  """
  def get_iroh_status_request(request_id \\ nil) do
    %{
      "type" => "get_iroh_status",
      "id" => request_id || UUID.uuid4()
    }
  end

  @doc """
  Build a configure_iroh request message.
  Tells the guest agent whether to start Iroh networking.
  """
  def configure_iroh_request(enabled, request_id \\ nil) do
    %{
      "type" => "configure_iroh",
      "id" => request_id || UUID.uuid4(),
      "enabled" => enabled
    }
  end

  @doc """
  Build a configure_secrets_auth request message.
  Tells the guest agent which Iroh NodeIds are authorized for secret injection.
  """
  def configure_secrets_auth_request(authorized_peers, request_id \\ nil) do
    %{
      "type" => "configure_secrets_auth",
      "id" => request_id || UUID.uuid4(),
      "authorized_peers" => authorized_peers
    }
  end

  @doc """
  Build an inject_secrets request message (`secrets_mode: :managed`).

  Delivers a host-escrowed LUKS passphrase over vsock. The guest creates the
  volume if none exists (sized `:init_size_mb`, min 32) or opens the existing
  one, then merges any `:entries` (secret material) and re-renders the tmpfs
  env file. Options:

    * `:init_size_mb` — size for first-time creation (default left to the guest)
    * `:entries` — map of `KEY => VALUE` secret material to merge after mount
    * `:request_id` — explicit request id (default: a fresh UUID)
  """
  def inject_secrets_request(passphrase, opts \\ []) when is_binary(passphrase) do
    %{
      "type" => "inject_secrets",
      "id" => opts[:request_id] || UUID.uuid4(),
      "passphrase" => passphrase
    }
    |> maybe_put("init_size_mb", opts[:init_size_mb])
    |> maybe_put("entries", opts[:entries])
  end

  @doc """
  Build an inject_identity request (Buzz nsec + relay URL).

  The guest writes `/run/mjolnir/buzz.env` on tmpfs. Do not log the
  returned map — it contains the nsec.
  """
  def inject_identity_request(identity, opts \\ []) do
    %{
      "type" => "inject_identity",
      "id" => opts[:request_id] || UUID.uuid4(),
      "entries" => Mjolnir.Identity.env_entries(identity)
    }
  end

  @doc """
  Write a named tmpfs file in `/run/mjolnir/`. `name` is a basename
  the guest allowlists (`git_signing_key`). Do not log `contents`.
  """
  def inject_file_request(name, contents, opts \\ [])
      when is_binary(name) and is_binary(contents) do
    %{
      "type" => "inject_file",
      "id" => opts[:request_id] || UUID.uuid4(),
      "name" => name,
      "contents" => contents
    }
  end

  @doc """
  Wipe the guest's LUKS volume key from kernel RAM before a memory snapshot.

  The guest no-ops (`ok: true, suspended: false`) when no mapper is open, so
  this is safe to send to a VM that never unlocked secrets.
  """
  def suspend_secrets_request(opts \\ []) do
    %{
      "type" => "suspend_secrets",
      "id" => opts[:request_id] || UUID.uuid4()
    }
  end

  @doc """
  Re-install the LUKS volume key after thaw.

  The guest's `inject_secrets` path also resumes a suspended mapper, so this
  is the explicit form. Use it when the caller already knows the volume is
  open-but-suspended and does not want create-or-open semantics.
  """
  def resume_secrets_request(passphrase, opts \\ []) when is_binary(passphrase) do
    %{
      "type" => "resume_secrets",
      "id" => opts[:request_id] || UUID.uuid4(),
      "passphrase" => passphrase
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Build a pty_open request message.
  Opens a new PTY session with the specified dimensions.

  When `session` is a binary, the guest attaches the PTY to that tmux session
  (creating it on first use) rather than spawning a private shell — which is what
  lets several clients share one terminal. The key is omitted entirely when nil so
  the message stays byte-identical to what older guest agents expect.
  """
  def pty_open_request(rows \\ 24, cols \\ 80, request_id \\ nil, session \\ nil) do
    base = %{
      "type" => "pty_open",
      "id" => request_id || UUID.uuid4(),
      "rows" => rows,
      "cols" => cols
    }

    if is_binary(session), do: Map.put(base, "session", session), else: base
  end

  @doc """
  Build a pty_resize request message.
  Resizes an existing PTY session.
  """
  def pty_resize_request(channel, rows, cols, request_id \\ nil) do
    %{
      "type" => "pty_resize",
      "id" => request_id || UUID.uuid4(),
      "channel" => channel,
      "rows" => rows,
      "cols" => cols
    }
  end

  @doc """
  Build a pty_close request message.
  Closes an existing PTY session.
  """
  def pty_close_request(channel) do
    %{
      "type" => "pty_close",
      "channel" => channel
    }
  end

  @doc """
  Build a spawn_sub_agent request message.
  Requests the guest to spawn a new sub-agent process.
  """
  def spawn_sub_agent_request(opts, request_id \\ nil) do
    %{
      "type" => "spawn_sub_agent",
      "id" => request_id || UUID.uuid4(),
      "opts" => opts
    }
  end

  @doc """
  Build a snapshot_self request message.
  Requests the guest to create a filesystem snapshot.
  """
  def snapshot_self_request(name, request_id \\ nil) do
    %{
      "type" => "snapshot_self",
      "id" => request_id || UUID.uuid4(),
      "name" => name
    }
  end

  @doc """
  Build an emit_event request message.
  Sends an event from the host to the guest.
  """
  def emit_event_request(event, payload, request_id \\ nil) do
    %{
      "type" => "emit_event",
      "id" => request_id || UUID.uuid4(),
      "event" => event,
      "payload" => payload
    }
  end

  @doc """
  Parse an iroh_ready message from the guest.

  The guest agent sends this proactively when its Iroh endpoint connects to relay.

  Returns `{:ok, %{node_id: string, ticket: string, generated_key: bool}}` or `{:error, reason}`.
  """
  def parse_iroh_ready(%{"type" => "iroh_ready", "node_id" => node_id, "ticket" => ticket} = msg) do
    {:ok,
     %{
       node_id: node_id,
       ticket: ticket,
       generated_key: Map.get(msg, "generated_key", true)
     }}
  end

  def parse_iroh_ready(_), do: {:error, :invalid_iroh_ready}

  @doc """
  Build a deliver_message message (host → guest push).
  Delivers a message from another VM into the guest's inbox.
  """
  def deliver_message(from_vm_id, payload, request_id \\ nil) do
    id = request_id || UUID.uuid4()

    %{
      "type" => "deliver_message",
      "id" => id,
      "message_id" => id,
      "from_vm_id" => from_vm_id,
      "payload" => payload
    }
  end

  @doc """
  Build a send_message_response message (host → guest).
  Response to a guest's send_message request.
  """
  def send_message_response(id, ok, error \\ nil) do
    msg = %{
      "type" => "send_message_response",
      "id" => id,
      "ok" => ok
    }

    if error, do: Map.put(msg, "error", error), else: msg
  end

  @doc """
  Build a signal_done_ack message (host → guest).
  Acknowledges the guest's signal_done request.
  """
  def signal_done_ack(id, ok) do
    %{
      "type" => "signal_done_ack",
      "id" => id,
      "ok" => ok
    }
  end
end
