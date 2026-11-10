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
  end
end
