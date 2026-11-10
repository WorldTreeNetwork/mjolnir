defmodule Mjolnir.MCP.ServerTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Mjolnir.API.Router

  @opts Router.init([])

  setup do
    original = Application.get_env(:mjolnir, :auth, [])
    Application.put_env(:mjolnir, :auth, bypass_localhost: true)
    on_exit(fn -> Application.put_env(:mjolnir, :auth, original) end)
    :ok
  end

  defp post_mcp(body, session \\ nil) do
    conn =
      conn(:post, "/mcp", Jason.encode!(body))
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2025-06-18")

    conn = if session, do: put_req_header(conn, "mcp-session-id", session), else: conn
    Router.call(conn, @opts)
  end

  defp mcp_request(%{"method" => "initialize"} = body) do
    response = post_mcp(body)

    Enum.each(get_resp_header(response, "mcp-session-id"), fn session ->
      on_exit(fn -> ExMCP.SessionManager.terminate_session(session) end)
    end)

    response
  end

  defp mcp_request(body) do
    initialized =
      mcp_request(%{
        "jsonrpc" => "2.0",
        "id" => "setup",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "0.1"}
        }
      })

    assert initialized.status == 200
    [session] = get_resp_header(initialized, "mcp-session-id")

    notification =
      post_mcp(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, session)

    assert notification.status in [200, 202, 204]
    post_mcp(body, session)
  end

  describe "MCP initialize" do
    test "returns valid JSON-RPC response with server capabilities" do
      conn =
        mcp_request(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "test", "version" => "0.1"}
          }
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["jsonrpc"] == "2.0"
      assert body["id"] == 1
      assert is_map(body["result"])
      assert is_map(body["result"]["capabilities"])
      assert is_map(body["result"]["serverInfo"])
    end
  end

  describe "MCP tools/list" do
    test "returns all 13 tools" do
      conn =
        mcp_request(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/list",
          "params" => %{}
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["jsonrpc"] == "2.0"
      tools = body["result"]["tools"]
      assert is_list(tools)
      assert length(tools) == 13

      tool_names = Enum.map(tools, & &1["name"])
      assert "spawn_vm" in tool_names
      assert "list_vms" in tool_names
      assert "get_vm" in tool_names
      assert "exec" in tool_names
      assert "stop_vm" in tool_names
      assert "create_snapshot" in tool_names
      assert "list_snapshots" in tool_names
      assert "get_snapshot" in tool_names
      assert "delete_snapshot" in tool_names
      assert "deliver_message" in tool_names
      assert "get_connection_ticket" in tool_names
      assert "list_dormant" in tool_names
      assert "await_pty" in tool_names
    end
  end

  describe "MCP tools/call" do
    test "list_vms is served through the HTTP transport" do
      response =
        mcp_request(%{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{"name" => "list_vms", "arguments" => %{}}
        })

      assert response.status == 200

      [%{"type" => "text", "text" => text}] =
        Jason.decode!(response.resp_body)["result"]["content"]

      assert is_list(Jason.decode!(text)["vms"])
    end

    test "get_vm reports a missing VM as a tool error" do
      response =
        mcp_request(%{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "tools/call",
          "params" => %{"name" => "get_vm", "arguments" => %{"vm_id" => "nonexistent"}}
        })

      assert response.status == 200
      result = Jason.decode!(response.resp_body)["result"]
      assert result["isError"] == true
      [%{"text" => text}] = result["content"]
      assert String.downcase(text) =~ "not found"
    end

    test "list_dormant is served through the HTTP transport" do
      response =
        mcp_request(%{
          "jsonrpc" => "2.0",
          "id" => 5,
          "method" => "tools/call",
          "params" => %{"name" => "list_dormant", "arguments" => %{}}
        })

      assert response.status == 200
      [%{"text" => text}] = Jason.decode!(response.resp_body)["result"]["content"]
      assert is_list(Jason.decode!(text)["dormant"])
    end
  end

  test "resources retain their URIs and JSON content through the transport" do
    response =
      mcp_request(%{"jsonrpc" => "2.0", "id" => 8, "method" => "resources/list", "params" => %{}})

    assert response.status == 200
    resources = Jason.decode!(response.resp_body)["result"]["resources"]

    assert Enum.sort(Enum.map(resources, & &1["uri"])) == [
             "mjolnir://dormant",
             "mjolnir://snapshots",
             "mjolnir://vms"
           ]

    response =
      mcp_request(%{
        "jsonrpc" => "2.0",
        "id" => 9,
        "method" => "resources/read",
        "params" => %{"uri" => "mjolnir://vms"}
      })

    assert response.status == 200
    [content] = Jason.decode!(response.resp_body)["result"]["contents"]
    assert content["uri"] == "mjolnir://vms"
    assert content["mimeType"] == "application/json"
    assert is_list(Jason.decode!(content["text"])["vms"])
  end

  describe "MCP auth enforcement" do
    setup do
      Application.put_env(:mjolnir, :auth, bypass_localhost: false)
      :ok
    end

    test "returns 401 for non-localhost without token" do
      conn =
        conn(
          :post,
          "/mcp",
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "initialize",
            "params" => %{}
          })
        )
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 401
    end
  end

  describe "existing routes unaffected" do
    test "GET /api/health still returns 200" do
      conn =
        conn(:get, "/api/health")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
    end

    test "GET /api/vms still returns 200" do
      conn =
        conn(:get, "/api/vms")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      # The subject here is "mounting MCP did not break the VM routes", not the
      # contents of a process-global StateStore. Asserting == [] made this test
      # fail whenever any other test left a record behind (mjolnir-7qh).
      assert is_list(body["vms"])
    end

    test "unknown route still returns 404" do
      conn =
        conn(:get, "/api/unknown")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 404
    end
  end
end
