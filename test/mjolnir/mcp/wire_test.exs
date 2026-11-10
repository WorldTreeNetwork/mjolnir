defmodule Mjolnir.MCP.WireTest do
  use ExUnit.Case, async: false

  test "legacy clients initialize and call tools over real HTTP" do
    original = Application.get_env(:mjolnir, :auth, [])
    Application.put_env(:mjolnir, :auth, Keyword.put(original, :bypass_localhost, true))
    on_exit(fn -> Application.put_env(:mjolnir, :auth, original) end)
    server = start_supervised!({Bandit, plug: Mjolnir.API.Router, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    url = "http://127.0.0.1:#{port}/mcp"

    headers = [
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", "2025-06-18"}
    ]

    {:ok, init} =
      Req.post(url,
        json: %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "wire-client", "version" => "1"}
          }
        },
        headers: headers,
        retry: false
      )

    assert init.status == 200
    assert init.body["result"]["protocolVersion"] == "2025-06-18"
    [session] = init.headers["mcp-session-id"]
    on_exit(fn -> ExMCP.SessionManager.terminate_session(session) end)
    headers = [{"mcp-session-id", session} | headers]

    {:ok, ready} =
      Req.post(url,
        json: %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        headers: headers,
        retry: false
      )

    assert ready.status in [200, 202, 204]

    {:ok, tools} =
      Req.post(url,
        json: %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}},
        headers: headers,
        retry: false
      )

    assert tools.status == 200
    assert length(tools.body["result"]["tools"]) == 13

    {:ok, result} =
      Req.post(url,
        json: %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{"name" => "list_vms", "arguments" => %{}}
        },
        headers: headers,
        retry: false
      )

    assert result.status == 200
    [%{"type" => "text", "text" => text}] = result.body["result"]["content"]
    assert is_list(Jason.decode!(text)["vms"])
    parent = self()

    stream_headers = [
      {"accept", "text/event-stream"} | Enum.reject(headers, fn {name, _} -> name == "accept" end)
    ]

    stream_result =
      Req.get(url,
        headers: stream_headers,
        retry: false,
        receive_timeout: 5_000,
        into: fn {:data, data}, pair ->
          send(parent, {:sse_data, elem(pair, 1).status, elem(pair, 1).headers, data})
          {:halt, pair}
        end
      )

    assert match?({:ok, _}, stream_result) or
             match?({:error, %Req.TransportError{reason: :closed}}, stream_result)

    assert_receive {:sse_data, 200, stream_headers, data}

    assert Enum.any?(
             stream_headers["content-type"],
             &String.starts_with?(&1, "text/event-stream")
           )

    assert byte_size(data) > 0
    assert {:ok, _} = ExMCP.SessionManager.get_session(session)
    {:ok, deleted} = Req.delete(url, headers: headers, retry: false)
    assert deleted.status in [200, 202, 204]
    assert {:ok, %{status: :terminated}} = ExMCP.SessionManager.get_session(session)

    {:ok, expired} =
      Req.post(url,
        json: %{"jsonrpc" => "2.0", "id" => 11, "method" => "tools/list", "params" => %{}},
        headers: headers,
        retry: false
      )

    assert expired.status in [400, 404]
  end
end
