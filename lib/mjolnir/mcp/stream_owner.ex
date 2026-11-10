defmodule Mjolnir.MCP.StreamOwner do
  @moduledoc false

  # Bandit requires adapter operations on the request owner. ExMCP's legacy
  # SSE handler writes from a child, so relay adapter calls to that owner.
  # No vendor code is modified, and the final connection uses its real adapter.
  def run(conn, callback) do
    owner = self()
    token = make_ref()
    {adapter, payload} = conn.adapter
    proxy = %{owner: owner, token: token}

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          try do
            result = callback.(%{conn | adapter: {__MODULE__.Adapter, proxy}})
            send(owner, {token, :result, result})
          catch
            kind, reason -> send(owner, {token, :raise, kind, reason, __STACKTRACE__})
          end
        end,
        [:link, :monitor]
      )

    loop(adapter, payload, token, worker, monitor)
  end

  defp loop(adapter, payload, token, worker, monitor) do
    receive do
      {:"$gen_call", from, {^token, function, args}} ->
        {reply, payload} = invoke(adapter, payload, function, args)
        GenServer.reply(from, reply)
        loop(adapter, payload, token, worker, monitor)

      {^token, :result, conn} ->
        Process.demonitor(monitor, [:flush])
        %{conn | adapter: {adapter, payload}}

      {^token, :raise, kind, reason, stack} ->
        Process.demonitor(monitor, [:flush])
        :erlang.raise(kind, reason, stack)

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        exit({:mcp_stream_worker_down, reason})

      {:tcp_closed, _} ->
        Process.exit(worker, :shutdown)
        loop(adapter, payload, token, worker, monitor)

      {:ssl_closed, _} ->
        Process.exit(worker, :shutdown)
        loop(adapter, payload, token, worker, monitor)

      _other ->
        loop(adapter, payload, token, worker, monitor)
    end
  end

  defp invoke(adapter, payload, function, args) do
    try do
      result = apply(adapter, function, [payload | args])

      case {function, result} do
        {function, {tag, body, next}}
        when function in [:send_resp, :send_file, :send_chunked, :chunk, :read_req_body] and
               tag in [:ok, :more] ->
          {{:state_result, tag, body}, next}

        {function, {:ok, next}} when function in [:upgrade, :inform] ->
          {{:state_result, :ok}, next}

        _ ->
          {result, payload}
      end
    catch
      kind, reason -> {{:raise, kind, reason, __STACKTRACE__}, payload}
    end
  end

  defmodule Adapter do
    @moduledoc false
    @behaviour Plug.Conn.Adapter
    for {name, arity} <- [
          send_resp: 4,
          send_file: 6,
          send_chunked: 3,
          chunk: 2,
          read_req_body: 2,
          inform: 3,
          push: 3,
          upgrade: 3,
          get_peer_data: 1,
          get_sock_data: 1,
          get_ssl_data: 1,
          get_http_protocol: 1
        ] do
      args = Macro.generate_arguments(arity - 1, __MODULE__)
      @impl true
      def unquote(name)(proxy, unquote_splicing(args)),
        do: call(proxy, unquote(name), [unquote_splicing(args)])
    end

    defp call(proxy, name, args) do
      case GenServer.call(proxy.owner, {proxy.token, name, args}, 30_000) do
        {:state_result, tag, body} -> {tag, body, proxy}
        {:state_result, :ok} -> {:ok, proxy}
        {:raise, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
        result -> result
      end
    end
  end
end
