defmodule Mjolnir.Syslog.Listener do
  @moduledoc """
  Ingests syslog from two paths into `Mjolnir.Syslog.Router`:

  1. **Guest vsock channel 2** — `Vsock.Connection` auto-registers this
     process as the ch2 handler on connect (`:continue :register_syslog`).
     Frames are tagged with `vm_id` so several VMs can emit at once.
  2. **Host UDP** — RFC 3164 datagrams. Bound only when `:udp_port` is set;
     unset means no socket (emitters stay on stdout). Loopback for host
     apps; bind `10.200.0.1` so guests can send to the hotel IP.

  EventBus type is `:app_log` iff the MSG is a JSON object carrying
  `schema`, regardless of source. Everything else is `:vm_syslog`.
  Records larger than 64 KiB are routed as malformed raw, never dropped.
  """

  use GenServer
  require Logger

  alias Mjolnir.Syslog.Message
  alias Mjolnir.Syslog.Parser
  alias Mjolnir.Syslog.Router

  @syslog_channel 2
  @max_record 65_536
  @udp_recbuf @max_record + 2048

  defstruct vm_buffers: %{}, udp_socket: nil, udp_port: nil

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Register a vsock connection for syslog on channel #{@syslog_channel}.

  Called from `Vsock.Connection` after connect, and from `:vm_spawned`
  when the payload (or `VM.get/1`) carries a live `vsock_conn`.
  """
  @spec register_connection(pid(), String.t(), non_neg_integer()) :: :ok
  def register_connection(conn_pid, vm_id, cid)
      when is_pid(conn_pid) and is_binary(vm_id) and is_integer(cid) do
    GenServer.cast(__MODULE__, {:register_connection, conn_pid, vm_id, cid})
  end

  @doc "The vsock channel number used for syslog data."
  def channel, do: @syslog_channel

  @doc """
  Bound UDP port, or `nil` if this listener did not bind.

  `server` is the registered name or pid (tests start extra listeners).
  """
  @spec udp_port(GenServer.server()) :: nil | :inet.port_number()
  def udp_port(server \\ __MODULE__) do
    GenServer.call(server, :udp_port)
  end

  @doc false
  @spec registered?(String.t(), GenServer.server()) :: boolean()
  def registered?(vm_id, server \\ __MODULE__) when is_binary(vm_id) do
    GenServer.call(server, {:registered?, vm_id})
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: Mjolnir.EventBus.subscribe(:all)
    {socket, port} = maybe_open_udp(opts)
    {:ok, %__MODULE__{udp_socket: socket, udp_port: port}}
  end

  @impl true
  def handle_call(:udp_port, _from, state) do
    {:reply, state.udp_port, state}
  end

  def handle_call({:registered?, vm_id}, _from, state) do
    {:reply, Map.has_key?(state.vm_buffers, vm_id), state}
  end

  @impl true
  def handle_cast({:register_connection, conn_pid, vm_id, cid}, state) do
    {:noreply, do_register(state, conn_pid, vm_id, cid)}
  end

  @impl true
  def handle_info({:vsock_data, @syslog_channel, data, meta}, state) do
    {vm_id, cid} = meta_id(meta)
    {:noreply, ingest_vsock(state, vm_id, cid, data)}
  end

  def handle_info({:vsock_data, @syslog_channel, data}, state) do
    # Untagged (handler registered as a bare pid). Only safe with one VM.
    case untagged_vm(state) do
      {:ok, vm_id, cid} ->
        {:noreply, ingest_vsock(state, vm_id, cid, data)}

      :error ->
        Logger.warning(
          "Syslog.Listener: untagged ch2 data with #{map_size(state.vm_buffers)} VMs; dropping"
        )

        {:noreply, state}
    end
  end

  def handle_info({:syslog_data, vm_id, cid, data}, state) do
    {:noreply, ingest_vsock(state, vm_id, cid, data)}
  end

  def handle_info({:udp, socket, _ip, _port, data}, %{udp_socket: socket} = state) do
    line = trim_nl(data)
    ingest_raw(line, udp_fallback_id(line), 0, :host)
    {:noreply, state}
  end

  def handle_info({:mjolnir_event, vm_id, :vm_spawned, payload}, state) do
    {:noreply, maybe_register_from_event(state, vm_id, payload)}
  end

  def handle_info({:mjolnir_event, vm_id, :vm_stopped, _payload}, state) do
    {:noreply, drop_vm(state, vm_id)}
  end

  def handle_info({:mjolnir_event, _vm_id, _event, _payload}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, drop_monitored(state, ref)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.udp_socket, do: :gen_udp.close(state.udp_socket)
    :ok
  end

  # ============================================================================
  # Registration
  # ============================================================================

  defp do_register(state, conn_pid, vm_id, cid) do
    unless Process.alive?(conn_pid) do
      Logger.warning("Syslog.Listener: vsock conn for VM #{vm_id} is dead, skip register")
      state
    else
      meta = %{vm_id: vm_id, cid: cid}

      case Mjolnir.Vsock.Connection.register_channel_handler(
             conn_pid,
             @syslog_channel,
             {self(), meta}
           ) do
        :ok ->
          Logger.debug("Syslog.Listener: registered channel #{@syslog_channel} for VM #{vm_id}")
          %{state | vm_buffers: put_registration(state.vm_buffers, vm_id, cid, conn_pid)}

        {:error, reason} ->
          Logger.warning(
            "Syslog.Listener: failed to register channel for VM #{vm_id}: #{inspect(reason)}"
          )

          state
      end
    end
  end

  defp maybe_register_from_event(state, vm_id, payload) do
    conn = event_conn(payload) || vm_conn(vm_id)
    cid = event_cid(payload) || Mjolnir.Vsock.cid(vm_id)

    if is_pid(conn) do
      do_register(state, conn, vm_id, cid)
    else
      state
    end
  end

  defp event_conn(payload) when is_map(payload) do
    conn = Map.get(payload, :vsock_conn) || Map.get(payload, "vsock_conn")
    if is_pid(conn), do: conn
  end

  defp event_conn(_), do: nil

  defp event_cid(payload) when is_map(payload) do
    case Map.get(payload, :vsock_cid) || Map.get(payload, "vsock_cid") do
      cid when is_integer(cid) and cid >= 0 -> cid
      _ -> nil
    end
  end

  defp event_cid(_), do: nil

  defp vm_conn(vm_id) do
    case Mjolnir.VM.get(vm_id) do
      {:ok, %{vsock_conn: conn}} when is_pid(conn) -> conn
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp put_registration(buffers, vm_id, cid, conn_pid) do
    buffers = drop_old_monitor(buffers, vm_id)
    mon = Process.monitor(conn_pid)
    buf = get_in(buffers, [vm_id, :buf]) || <<>>

    Map.put(buffers, vm_id, %{cid: cid, buf: buf, conn: conn_pid, mon: mon})
  end

  defp drop_old_monitor(buffers, vm_id) do
    case Map.get(buffers, vm_id) do
      %{mon: ref} when is_reference(ref) ->
        Process.demonitor(ref, [:flush])
        buffers

      _ ->
        buffers
    end
  end

  defp drop_vm(state, vm_id) do
    %{state | vm_buffers: drop_old_monitor(state.vm_buffers, vm_id) |> Map.delete(vm_id)}
  end

  defp drop_monitored(state, ref) do
    match =
      Enum.find(state.vm_buffers, fn {_id, meta} -> Map.get(meta, :mon) == ref end)

    case match do
      {vm_id, _} ->
        %{state | vm_buffers: Map.delete(state.vm_buffers, vm_id)}

      nil ->
        state
    end
  end

  defp untagged_vm(%{vm_buffers: buffers}) do
    case Map.to_list(buffers) do
      [{vm_id, meta}] -> {:ok, vm_id, meta.cid}
      _ -> :error
    end
  end

  defp meta_id(%{vm_id: vm_id, cid: cid}), do: {vm_id, cid}
  defp meta_id(%{vm_id: vm_id}), do: {vm_id, 0}
  defp meta_id({vm_id, cid}) when is_binary(vm_id), do: {vm_id, cid}
  defp meta_id(vm_id) when is_binary(vm_id), do: {vm_id, 0}

  # ============================================================================
  # Ingest
  # ============================================================================

  defp ingest_vsock(state, vm_id, cid, data) do
    buf =
      case Map.get(state.vm_buffers, vm_id) do
        %{buf: b} -> b
        _ -> <<>>
      end

    remaining = append_and_split(buf, data, vm_id, cid)
    %{state | vm_buffers: put_buf(state.vm_buffers, vm_id, cid, remaining)}
  end

  defp put_buf(buffers, vm_id, cid, remaining) do
    Map.update(
      buffers,
      vm_id,
      %{cid: cid, buf: remaining, conn: nil, mon: nil},
      fn meta -> %{meta | buf: remaining, cid: cid} end
    )
  end

  defp append_and_split(buf, data, vm_id, cid) do
    new_buf = buf <> data
    {lines, remaining} = split_lines(new_buf)

    Enum.each(lines, &ingest_raw(&1, vm_id, cid, :guest))

    if byte_size(remaining) > @max_record do
      ingest_raw(remaining, vm_id, cid, :guest)
      <<>>
    else
      remaining
    end
  end

  defp split_lines(data) do
    parts = :binary.split(data, "\n", [:global])
    {complete, [tail]} = Enum.split(parts, length(parts) - 1)
    {Enum.reject(complete, &(&1 == "")), tail}
  end

  defp trim_nl(data) when is_binary(data) do
    size = byte_size(data)

    if size > 0 and :binary.last(data) == ?\n do
      binary_part(data, 0, size - 1)
    else
      data
    end
  end

  defp ingest_raw(raw, vm_id, cid, source) when is_binary(raw) do
    cond do
      byte_size(raw) > @max_record ->
        Router.route(vm_id, cid, %Message{raw: clip(raw)})

      not String.valid?(raw) ->
        Router.route(vm_id, cid, %Message{raw: clip(raw)})

      true ->
        parsed =
          case Parser.parse(raw) do
            {:ok, msg} -> msg
            {:error, :malformed, msg} -> msg
          end

        route_parsed(parsed, vm_id, cid, source)
    end
  end

  defp route_parsed(msg, vm_id, cid, source) do
    case decode_app_log(json_candidate(msg)) do
      {:ok, app_id, record} ->
        Router.route_app_log(app_id, Map.put(record, "source", source_string(source)))

      :error ->
        Router.route(vm_id, cid, msg)
    end
  end

  defp json_candidate(%Message{message: m}) when is_binary(m) and m != "" do
    String.trim(m)
  end

  defp json_candidate(%Message{raw: raw}) when is_binary(raw), do: String.trim(raw)
  defp json_candidate(_), do: nil

  defp decode_app_log(nil), do: :error

  defp decode_app_log(text) do
    case Jason.decode(text) do
      {:ok, obj} when is_map(obj) ->
        if app_log_schema?(obj) do
          {:ok, app_id(obj), obj}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp app_log_schema?(obj) do
    case Map.get(obj, "schema") do
      schema when is_binary(schema) and schema != "" -> true
      _ -> false
    end
  end

  defp app_id(obj) do
    case obj["app"] || obj["name"] do
      id when is_binary(id) and id != "" -> id
      _ -> "unknown"
    end
  end

  defp source_string(:guest), do: "guest"
  defp source_string(:host), do: "host"
  defp source_string(other) when is_atom(other), do: Atom.to_string(other)

  defp udp_fallback_id(line) do
    case Parser.parse(line) do
      {:ok, %Message{hostname: host}} when is_binary(host) and host != "" -> host
      _ -> "host"
    end
  end

  defp clip(raw) do
    max = @max_record + 1

    if byte_size(raw) > max do
      binary_part(raw, 0, max)
    else
      raw
    end
  end

  # ============================================================================
  # UDP
  # ============================================================================

  defp maybe_open_udp(opts) do
    cfg = Application.get_env(:mjolnir, :syslog, [])

    port =
      case Keyword.fetch(opts, :udp_port) do
        {:ok, p} -> p
        :error -> Keyword.get(cfg, :udp_port)
      end

    host =
      case Keyword.fetch(opts, :udp_host) do
        {:ok, h} -> h
        :error -> Keyword.get(cfg, :udp_host, {127, 0, 0, 1})
      end

    open_udp(host, port)
  end

  defp open_udp(_host, port) when not is_integer(port), do: {nil, nil}

  defp open_udp(host, port) when is_integer(port) and port >= 0 do
    case parse_ip(host) do
      {:ok, ip} ->
        sock_opts = [
          :binary,
          :inet,
          {:ip, ip},
          {:active, true},
          {:reuseaddr, true},
          {:recbuf, @udp_recbuf}
        ]

        case :gen_udp.open(port, sock_opts) do
          {:ok, socket} ->
            {:ok, actual} = :inet.port(socket)

            Logger.info(
              "Syslog.Listener: UDP ingest on #{:inet.ntoa(ip)}:#{actual} (max #{@max_record} B)"
            )

            {socket, actual}

          {:error, reason} ->
            Logger.error(
              "Syslog.Listener: UDP bind #{inspect(host)}:#{port} failed: #{inspect(reason)}"
            )

            {nil, nil}
        end

      {:error, reason} ->
        Logger.error("Syslog.Listener: invalid udp_host #{inspect(host)}: #{inspect(reason)}")
        {nil, nil}
    end
  end

  defp parse_ip({a, b, c, d} = ip)
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    {:ok, ip}
  end

  defp parse_ip(host) when is_binary(host) do
    :inet.parse_address(String.to_charlist(host))
  end

  defp parse_ip(host) when is_list(host), do: :inet.parse_address(host)
  defp parse_ip(other), do: {:error, {:bad_ip, other}}
end
