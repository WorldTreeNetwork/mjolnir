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

  defp mcp_request(body) when is_map(body) do
    conn(:post, "/mcp", Jason.encode!(body))
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
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
    test "list_vms returns empty list in test env" do
      conn =
        mcp_request(%{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{"name" => "list_vms", "arguments" => %{}}
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["jsonrpc"] == "2.0"
      result = body["result"]
      assert is_map(result)
      content = result["content"]
      assert is_list(content)
      assert length(content) > 0
      first = hd(content)
      assert first["type"] == "text"
      inner = Jason.decode!(first["text"])
      assert inner["vms"] == []
    end

    test "get_vm returns error for non-existent VM" do
      conn =
        mcp_request(%{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "tools/call",
          "params" => %{"name" => "get_vm", "arguments" => %{"vm_id" => "nonexistent"}}
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      result = body["result"]

      assert result["isError"] == true || result["is_error?"] == true ||
               (is_list(result["content"]) && hd(result["content"])["text"] =~ "not found")
    end

    test "list_dormant returns dormant list" do
      conn =
        mcp_request(%{
          "jsonrpc" => "2.0",
          "id" => 5,
          "method" => "tools/call",
          "params" => %{"name" => "list_dormant", "arguments" => %{}}
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      result = body["result"]
      content = result["content"]
      assert is_list(content)
      first = hd(content)
      assert first["type"] == "text"
      inner = Jason.decode!(first["text"])
      assert is_list(inner["dormant"])
    end
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
      assert body["vms"] == []
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
