defmodule Mjolnir.MCP.AuthorizationTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  alias Mjolnir.MCP.{Authorization, Server}
  alias Mjolnir.MCP.Plug, as: MCPPlug

  defmodule OwnedVM do
    use GenServer

    def start_link({id, owner}),
      do:
        GenServer.start_link(__MODULE__, {id, owner},
          name: {:via, Registry, {Mjolnir.VMRegistry, id}}
        )

    def init({id, owner}), do: {:ok, %{id: id, owner_id: owner}}
    def handle_call(:get_state, _, state), do: {:reply, state, state}
  end

  defp actor(uid, scope), do: %{kind: :user, user_id: uid, scope: scope}

  defp request(context, body, session \\ nil) do
    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2025-06-18")
      |> assign(:principal_kind, context.kind)
      |> assign(:user_id, context.user_id)
      |> assign(:claims, %{"scope" => context.scope})

    conn = if session, do: put_req_header(conn, "mcp-session-id", session), else: conn

    conn =
      Plug.Parsers.call(
        conn,
        Plug.Parsers.init(parsers: [:json], pass: ["application/json"], json_decoder: Jason)
      )

    MCPPlug.call(conn, [])
  end

  defp initialize(context) do
    response =
      request(context, %{
        "jsonrpc" => "2.0",
        "id" => "init",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "auth-test", "version" => "1"}
        }
      })

    assert response.status == 200
    [session] = get_resp_header(response, "mcp-session-id")
    on_exit(fn -> ExMCP.SessionManager.terminate_session(session) end)

    notification =
      request(context, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, session)

    assert notification.status in [200, 202, 204]
    session
  end

  test "publish credentials and capability-only principals cannot enter MCP" do
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}}

    for context <- [
          %{kind: :sites, user_id: "sites_token:test", scope: "sites:publish"},
          %{kind: :capability, user_id: "capability", scope: ""}
        ] do
      assert request(context, body).status == 403
    end
  end

  test "a read-only user cannot invoke a mutation or forge its scope in metadata" do
    body = %{
      "method" => "tools/call",
      "params" => %{"name" => "spawn_vm", "arguments" => %{}},
      "_meta" => %{"scope" => "vms:spawn", "user_id" => "localhost"}
    }

    refute Authorization.request_allowed?(actor("alice", "vms:read"), body)
    assert request(actor("alice", "vms:read"), body).status == 403
  end

  test "every advertised tool has an explicit scope and batches cannot bypass it" do
    {:ok, tools, nil, _} = Server.handle_list_tools(nil, %{})

    for tool <- tools do
      refute Authorization.request_allowed?(actor("alice", "unrelated"), %{
               "method" => "tools/call",
               "params" => %{"name" => tool.name}
             })
    end

    refute Authorization.request_allowed?(actor("alice", "vms:read"), [
             %{"method" => "ping"},
             %{"method" => "tools/call", "params" => %{"name" => "stop_vm"}}
           ])

    refute Authorization.request_allowed?(actor("alice", "vms:read"), %{
             "method" => "tools/call",
             "params" => %{"name" => "unknown"}
           })
  end

  test "owners can act on their VM while strangers get the same denial as a missing id" do
    id = "mcp-owner-#{System.unique_integer([:positive])}"
    pid = start_supervised!({OwnedVM, {id, "alice"}})

    assert :ok =
             Authorization.authorize_tool(actor("alice", "vms:exec"), "exec", %{"vm_id" => id})

    denied = Authorization.authorize_tool(actor("bob", "vms:exec"), "exec", %{"vm_id" => id})

    assert denied ==
             Authorization.authorize_tool(actor("bob", "vms:exec"), "exec", %{
               "vm_id" => "missing"
             })

    assert {:error, "Not found"} = denied

    assert {:ok, %{isError: true}, _} =
             Server.handle_call_tool("stop_vm", %{"vm_id" => id}, actor("bob", "vms:stop"))

    assert Process.alive?(pid)
  end

  test "collections filter legacy, other-owner and missing actor entries" do
    alice = actor("alice", "vms:read")
    assert Authorization.visible?(alice, %{owner_id: "alice"})
    refute Authorization.visible?(alice, %{owner_id: "bob"})
    refute Authorization.visible?(alice, %{owner_id: nil})
    refute Authorization.visible?(%{}, %{owner_id: "alice"})

    refute Authorization.visible?(
             %{kind: :sites, user_id: "sites_token:test", scope: "vms:read"},
             %{owner_id: "sites_token:test"}
           )
  end

  test "a session stays bound to its authenticated principal" do
    alice = actor("alice", "vms:read")
    session = initialize(alice)

    response =
      request(
        actor("bob", "vms:read"),
        %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list", "params" => %{}},
        session
      )

    assert response.status in [400, 403, 404]
    assert is_map(Jason.decode!(response.resp_body)["error"])
  end

  test "an attenuated current token cannot reuse initialized session privileges" do
    session = initialize(actor("alice", "vms:read vms:spawn"))

    response =
      request(
        actor("alice", "vms:read"),
        %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "tools/call",
          "params" => %{"name" => "spawn_vm", "arguments" => %{}}
        },
        session
      )

    assert response.status == 403
  end

  test "resources use their own scope and serialized actor state contains no credential" do
    refute Authorization.request_allowed?(actor("alice", "vms:read"), %{
             "method" => "resources/read",
             "params" => %{"uri" => "mjolnir://snapshots"}
           })

    conn =
      Plug.Test.conn(:post, "/mcp")
      |> assign(:principal_kind, :user)
      |> assign(:user_id, "alice")
      |> assign(:claims, %{"scope" => "vms:read", "private" => "must-not-retain"})
      |> put_req_header("authorization", "Bearer must-not-retain")

    assert Authorization.context(conn) == actor("alice", "vms:read")
  end

  test "cancellation reaches only the request's owning session" do
    alice = actor("alice", "vms:read")
    bob = actor("bob", "vms:read")
    a = initialize(alice)
    b = initialize(bob)
    scope = {:session, Server, a}

    ExMCP.Server.Cancellation.track(scope, 42, fn ->
      foreign =
        request(
          bob,
          %{
            "jsonrpc" => "2.0",
            "method" => "notifications/cancelled",
            "params" => %{"requestId" => 42}
          },
          b
        )

      assert foreign.status in [200, 202, 204]
      refute ExMCP.Server.Cancellation.cancelled?(scope, 42)

      own =
        request(
          alice,
          %{
            "jsonrpc" => "2.0",
            "method" => "notifications/cancelled",
            "params" => %{"requestId" => 42}
          },
          a
        )

      assert own.status in [200, 202, 204]
      assert ExMCP.Server.Cancellation.cancelled?(scope, 42)
    end)

    refute ExMCP.Server.Cancellation.cancelled?(scope, 42)
  end

  test "unreviewed task methods and unparsed POST bodies fail closed" do
    context = actor("alice", "vms:read")
    refute Authorization.request_allowed?(context, %{"method" => "tasks/result", "params" => %{}})

    conn =
      Plug.Test.conn(
        :post,
        "/mcp",
        Jason.encode!(%{"method" => "tools/call", "params" => %{"name" => "spawn_vm"}})
      )
      |> assign(:principal_kind, :user)
      |> assign(:user_id, "alice")
      |> assign(:claims, %{"scope" => "vms:read"})

    assert MCPPlug.call(conn, []).status == 403
  end
end
