# Mjolnir MCP Server — Elixir-Native Implementation

**Status**: Active — Ready for Implementation
**Date**: 2026-02-26
**Priority**: Phase 1 (immediate)

## 1. Goal

Embed an MCP (Model Context Protocol) server directly in the Mjolnir Elixir application so that any MCP-compatible AI agent can discover and invoke Mjolnir's full VM lifecycle API. No sidecar, no proxy layer, no extra process — the MCP endpoint lives on the BEAM alongside everything else.

**Done when**: An agent connects to `http://<host>:4000/mcp` via Streamable HTTP, calls `tools/list`, and successfully `spawn_vm` → `exec` → `stop_vm`.

## 2. Why Elixir-Native (Not a Sidecar)

- **No HTTP hop**: Tool calls go directly to `Mjolnir.VM`, `Mjolnir.BTRFS`, `Mjolnir.DormantRegistry` — no serialization round-trip through a proxy
- **OTP supervision**: The MCP server is a supervised GenServer. It crashes, it restarts. Same guarantees as every other Mjolnir component.
- **EventBus integration**: SSE streaming for long-running operations (VM boot progress, resource subscriptions) wires directly into `Mjolnir.EventBus` pub/sub
- **Single deployment**: One binary, one port, one auth stack. The MCP endpoint is just another route alongside the REST API.
- **Sovereignty-aligned**: No dependency on a TypeScript runtime or npm ecosystem for core infrastructure

## 3. Library Choice: `ex_mcp`

Use [`ex_mcp`](https://hex.pm/packages/ex_mcp) (v0.7.x). It provides:

- `use ExMCP.Server` DSL for declaring tools, resources, and prompts
- `handle_tool_call/3`, `handle_resource_read/3` callbacks
- HTTP/SSE transport (Streamable HTTP compliant)
- MCP protocol v2025-06-18 support (current stable)
- Progress notifications, resource subscriptions, logging

Add to `mix.exs`:

```elixir
{:ex_mcp, "~> 0.7"}
```

## 4. Architecture

```
Mjolnir.Supervisor (one_for_one)
├── Mjolnir.VMRegistry
├── Mjolnir.VMSupervisor
├── Mjolnir.TaskSupervisor
├── Mjolnir.EventBus
├── Mjolnir.DormantRegistry
├── Mjolnir.MCP.Server          ← NEW: ExMCP.Server GenServer
└── Bandit (port 4000)
    ├── Mjolnir.API.Router       (existing REST at /api/*)
    └── Mjolnir.MCP.Plug         ← NEW: forwards /mcp to ExMCP
```

The MCP server runs as a supervised child. Bandit routes `/mcp` requests to a Plug that bridges into `ex_mcp`'s HTTP transport. The REST API continues unchanged at `/api/*`.

## 5. Module Design

### 5.1 `Mjolnir.MCP.Server`

The core MCP handler. Declares all tools and resources, implements callbacks.

```elixir
defmodule Mjolnir.MCP.Server do
  use ExMCP.Server

  # ── Tools ──────────────────────────────────────────────

  deftool "spawn_vm" do
    meta do
      name "Spawn VM"
      description "Create and boot a new microVM. Returns the VM's UUID and status. The VM is ready for commands within ~2 seconds."
    end

    input_schema %{
      type: "object",
      properties: %{
        base_image: %{type: "string", description: "Base rootfs image name (e.g. 'ubuntu-24.04'). Defaults to server config."},
        memory_mb: %{type: "integer", minimum: 128, maximum: 8192, description: "RAM in MB. Default: 512."},
        vcpus: %{type: "integer", minimum: 1, maximum: 8, description: "Virtual CPUs. Default: 1."},
        ssh_public_key: %{type: "string", description: "SSH public key to inject for key-based auth."},
        snapshot: %{type: "string", description: "Restore from this named snapshot instead of a fresh base image."},
        rootfs_size_mb: %{type: "integer", minimum: 256, description: "Root filesystem size in MB. Default: 2048."},
        enable_iroh: %{type: "boolean", description: "Enable Iroh P2P networking."}
      }
    }
  end

  deftool "list_vms" do
    meta do
      name "List VMs"
      description "List all running microVMs with their state, hypervisor, and connectivity info."
    end
    input_schema %{type: "object", properties: %{}}
  end

  deftool "get_vm" do
    meta do
      name "Get VM"
      description "Get detailed info about a specific VM including config, boot time, and connection ticket."
    end
    input_schema %{
      type: "object",
      properties: %{vm_id: %{type: "string", format: "uuid", description: "UUID of the target VM."}},
      required: ["vm_id"]
    }
  end

  deftool "exec" do
    meta do
      name "Execute Command"
      description "Execute a shell command inside a running VM. Returns stdout, stderr, and exit code. Command runs via sh -c."
    end
    input_schema %{
      type: "object",
      properties: %{
        vm_id: %{type: "string", format: "uuid", description: "UUID of the target VM."},
        command: %{type: "string", minLength: 1, description: "Shell command to execute."},
        timeout: %{type: "integer", minimum: 1000, maximum: 300_000, description: "Timeout in ms. Default: 30000."}
      },
      required: ["vm_id", "command"]
    }
  end

  deftool "stop_vm" do
    meta do
      name "Stop VM"
      description "Stop and destroy a running VM. Irreversible — ephemeral state is lost. Snapshots taken before stopping are preserved."
    end
    input_schema %{
      type: "object",
      properties: %{vm_id: %{type: "string", format: "uuid", description: "UUID of the VM to stop."}},
      required: ["vm_id"]
    }
  end

  deftool "create_snapshot" do
    meta do
      name "Create Snapshot"
      description "Snapshot a running VM's filesystem. The snapshot is instant (BTRFS CoW) and can spawn new VMs."
    end
    input_schema %{
      type: "object",
      properties: %{
        vm_id: %{type: "string", format: "uuid", description: "UUID of the VM to snapshot."},
        name: %{type: "string", minLength: 1, maxLength: 128, description: "Unique name for this snapshot."},
        compact: %{type: "boolean", description: "Compact snapshot to reduce disk usage (slower)."}
      },
      required: ["vm_id", "name"]
    }
  end

  deftool "list_snapshots" do
    meta do
      name "List Snapshots"
      description "List all available snapshots that can be used to spawn VMs."
    end
    input_schema %{type: "object", properties: %{}}
  end

  deftool "get_snapshot" do
    meta do
      name "Get Snapshot"
      description "Get metadata for a specific snapshot by name."
    end
    input_schema %{
      type: "object",
      properties: %{name: %{type: "string", minLength: 1, description: "Snapshot name."}},
      required: ["name"]
    }
  end

  deftool "delete_snapshot" do
    meta do
      name "Delete Snapshot"
      description "Permanently delete a snapshot by name."
    end
    input_schema %{
      type: "object",
      properties: %{name: %{type: "string", minLength: 1, description: "Snapshot name to delete."}},
      required: ["name"]
    }
  end

  deftool "deliver_message" do
    meta do
      name "Deliver Message"
      description "Send a message to a VM for inter-VM communication or coroutine wake-up. If the VM is dormant, it will be restored automatically."
    end
    input_schema %{
      type: "object",
      properties: %{
        vm_id: %{type: "string", format: "uuid", description: "Target VM UUID."},
        from_vm_id: %{type: "string", description: "Source VM UUID or 'external'."},
        payload: %{type: "object", description: "Arbitrary JSON payload to deliver."}
      },
      required: ["vm_id"]
    }
  end

  deftool "get_connection_ticket" do
    meta do
      name "Get Connection Ticket"
      description "Get an Iroh connection ticket for direct P2P shell access to a VM."
    end
    input_schema %{
      type: "object",
      properties: %{vm_id: %{type: "string", format: "uuid", description: "UUID of the VM."}},
      required: ["vm_id"]
    }
  end

  deftool "list_dormant" do
    meta do
      name "List Dormant VMs"
      description "List VMs that have been snapshotted and stopped. They restore automatically when a message arrives."
    end
    input_schema %{type: "object", properties: %{}}
  end

  deftool "await_pty" do
    meta do
      name "Await PTY"
      description "Wait for a VM's PTY/shell to become ready. Returns a connection ticket."
    end
    input_schema %{
      type: "object",
      properties: %{
        vm_id: %{type: "string", format: "uuid", description: "UUID of the VM."},
        timeout: %{type: "integer", minimum: 1000, description: "Timeout in ms. Default: 30000."}
      },
      required: ["vm_id"]
    }
  end

  # ── Resources ──────────────────────────────────────────

  defresource "mjolnir://vms" do
    meta do
      name "VM List"
      description "All running VMs with status summary"
    end
    mime_type "application/json"
  end

  defresource "mjolnir://snapshots" do
    meta do
      name "Snapshot List"
      description "All available snapshots with metadata"
    end
    mime_type "application/json"
  end

  defresource "mjolnir://dormant" do
    meta do
      name "Dormant VMs"
      description "Dormant VMs with pending message counts"
    end
    mime_type "application/json"
  end

  # ── Tool Handlers ──────────────────────────────────────

  @impl true
  def handle_tool_call("spawn_vm", args, state) do
    opts = args_to_spawn_opts(args)

    case Mjolnir.VM.spawn(opts) do
      {:ok, vm} ->
        {:ok, %{content: [text(Jason.encode!(Mjolnir.API.Views.render_vm(vm)))]}, state}

      {:error, reason} ->
        {:ok, %{content: [text("Spawn failed: #{inspect(reason)}")], is_error?: true}, state}
    end
  end

  def handle_tool_call("list_vms", _args, state) do
    vms = Mjolnir.VM.list() |> Enum.map(&Mjolnir.API.Views.render_vm_summary/1)
    {:ok, %{content: [text(Jason.encode!(%{vms: vms}))]}, state}
  end

  def handle_tool_call("get_vm", %{"vm_id" => id}, state) do
    case Mjolnir.VM.get(id) do
      {:ok, vm} ->
        {:ok, %{content: [text(Jason.encode!(Mjolnir.API.Views.render_vm(vm)))]}, state}
      {:error, :not_found} ->
        {:ok, %{content: [text("VM not found: #{id}")], is_error?: true}, state}
    end
  end

  def handle_tool_call("exec", %{"vm_id" => id, "command" => cmd} = args, state) do
    timeout = Map.get(args, "timeout", 30_000)

    case Mjolnir.VM.exec(id, cmd, timeout: timeout) do
      {:ok, output} ->
        {:ok, %{content: [text(output)]}, state}

      {:error, {:exit_code, code, stderr}} ->
        {:ok, %{content: [text("Exit code #{code}\n#{stderr}")]}, state}

      {:error, :not_found} ->
        {:ok, %{content: [text("VM not found: #{id}")], is_error?: true}, state}

      {:error, reason} ->
        {:ok, %{content: [text("Exec failed: #{inspect(reason)}")], is_error?: true}, state}
    end
  end

  def handle_tool_call("stop_vm", %{"vm_id" => id}, state) do
    case Mjolnir.VM.stop(id) do
      :ok ->
        {:ok, %{content: [text(~s({"ok": true}))]}, state}
      {:error, :not_found} ->
        {:ok, %{content: [text("VM not found: #{id}")], is_error?: true}, state}
      {:error, reason} ->
        {:ok, %{content: [text("Stop failed: #{inspect(reason)}")], is_error?: true}, state}
    end
  end

  def handle_tool_call("create_snapshot", %{"vm_id" => id, "name" => name} = args, state) do
    compact = Map.get(args, "compact", false)

    case Mjolnir.VM.snapshot(id, name, compact: compact) do
      {:ok, metadata} ->
        {:ok, %{content: [text(Jason.encode!(metadata))]}, state}
      {:error, {:snapshot_exists, _}} ->
        {:ok, %{content: [text("Snapshot '#{name}' already exists")], is_error?: true}, state}
      {:error, :not_found} ->
        {:ok, %{content: [text("VM not found: #{id}")], is_error?: true}, state}
      {:error, reason} ->
        {:ok, %{content: [text("Snapshot failed: #{inspect(reason)}")], is_error?: true}, state}
    end
  end

  def handle_tool_call("list_snapshots", _args, state) do
    case Mjolnir.BTRFS.list_snapshots() do
      {:ok, snapshots} ->
        {:ok, %{content: [text(Jason.encode!(%{snapshots: snapshots}))]}, state}
      {:error, reason} ->
        {:ok, %{content: [text("Failed: #{inspect(reason)}")], is_error?: true}, state}
    end
  end

  def handle_tool_call("get_snapshot", %{"name" => name}, state) do
    case Mjolnir.BTRFS.get_snapshot(name) do
      {:ok, %{metadata: metadata}} ->
        {:ok, %{content: [text(Jason.encode!(metadata))]}, state}
      {:error, {:snapshot_not_found, _}} ->
        {:ok, %{content: [text("Snapshot not found: #{name}")], is_error?: true}, state}
      {:error, reason} ->
        {:ok, %{content: [text("Failed: #{inspect(reason)}")], is_error?: true}, state}
    end
  end

  def handle_tool_call("delete_snapshot", %{"name" => name}, state) do
    case Mjolnir.BTRFS.delete_snapshot(name) do
      :ok ->
        {:ok, %{content: [text(~s({"ok": true}))]}, state}
      {:error, {:snapshot_not_found, _}} ->
        {:ok, %{content: [text("Snapshot not found: #{name}")], is_error?: true}, state}
      {:error, reason} ->
        {:ok, %{content: [text("Failed: #{inspect(reason)}")], is_error?: true}, state}
    end
  end

  def handle_tool_call("deliver_message", %{"vm_id" => id} = args, state) do
    from = Map.get(args, "from_vm_id", "external")
    payload = Map.get(args, "payload", %{})

    case Mjolnir.VM.deliver_message(id, from, payload) do
      :ok ->
        {:ok, %{content: [text(~s({"ok": true}))]}, state}
      {:error, :not_found} ->
        {:ok, %{content: [text("VM not found: #{id}")], is_error?: true}, state}
      {:error, reason} ->
        {:ok, %{content: [text("Failed: #{inspect(reason)}")], is_error?: true}, state}
    end
  end

  def handle_tool_call("get_connection_ticket", %{"vm_id" => id}, state) do
    case Mjolnir.VM.connection_info(id) do
      {:ok, ticket, iroh_addr} ->
        {:ok, %{content: [text(Jason.encode!(%{ticket: ticket, iroh_addr: iroh_addr}))]}, state}
      {:error, :not_ready} ->
        {:ok, %{content: [text("VM not ready yet — Iroh endpoint still initializing")], is_error?: true}, state}
      {:error, :not_found} ->
        {:ok, %{content: [text("VM not found: #{id}")], is_error?: true}, state}
    end
  end

  def handle_tool_call("list_dormant", _args, state) do
    dormant =
      Mjolnir.DormantRegistry.list()
      |> Enum.map(fn entry ->
        %{
          vm_id: entry.vm_id,
          snapshot_name: entry.snapshot_name,
          dormant_since: DateTime.to_iso8601(entry.dormant_since),
          pending_messages: length(entry.pending_messages),
          state: entry.state
        }
      end)

    {:ok, %{content: [text(Jason.encode!(%{dormant: dormant}))]}, state}
  end

  def handle_tool_call("await_pty", %{"vm_id" => id} = args, state) do
    timeout = Map.get(args, "timeout", 30_000)

    case Mjolnir.VM.await_pty(id, timeout) do
      {:ok, ticket} ->
        {:ok, %{content: [text(Jason.encode!(%{ticket: ticket}))]}, state}
      {:error, :timeout} ->
        {:ok, %{content: [text("Timed out waiting for PTY readiness")], is_error?: true}, state}
      {:error, :not_found} ->
        {:ok, %{content: [text("VM not found: #{id}")], is_error?: true}, state}
    end
  end

  # ── Resource Handlers ──────────────────────────────────

  @impl true
  def handle_resource_read("mjolnir://vms", _uri, state) do
    vms = Mjolnir.VM.list() |> Enum.map(&Mjolnir.API.Views.render_vm_summary/1)
    {:ok, [json(%{vms: vms})], state}
  end

  def handle_resource_read("mjolnir://snapshots", _uri, state) do
    case Mjolnir.BTRFS.list_snapshots() do
      {:ok, snapshots} -> {:ok, [json(%{snapshots: snapshots})], state}
      {:error, reason} -> {:error, inspect(reason), state}
    end
  end

  def handle_resource_read("mjolnir://dormant", _uri, state) do
    dormant =
      Mjolnir.DormantRegistry.list()
      |> Enum.map(fn e ->
        %{vm_id: e.vm_id, snapshot_name: e.snapshot_name, pending_messages: length(e.pending_messages)}
      end)

    {:ok, [json(%{dormant: dormant})], state}
  end

  # ── Helpers ────────────────────────────────────────────

  @spawn_keys ~w(base_image memory_mb vcpus ssh_public_key snapshot rootfs_size_mb enable_iroh)

  defp args_to_spawn_opts(args) do
    args
    |> Map.take(@spawn_keys)
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      Map.put(acc, String.to_existing_atom(k), v)
    end)
  end

  defp text(content), do: %{type: "text", text: content}

  defp json(data), do: %{type: "text", text: Jason.encode!(data), mimeType: "application/json"}
end
```

### 5.2 `Mjolnir.MCP.Plug`

Thin Plug that bridges Bandit HTTP requests to the `ex_mcp` server process. This is the glue between the existing Bandit webserver and `ex_mcp`'s HTTP transport.

```elixir
defmodule Mjolnir.MCP.Plug do
  @moduledoc """
  Plug adapter that routes /mcp requests to the ExMCP server.
  Handles Streamable HTTP: POST for JSON-RPC, GET for SSE streams.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # Delegate to ex_mcp's HTTP transport handler
    # The exact integration depends on ex_mcp's Plug support.
    # If ex_mcp doesn't provide a Plug adapter, implement the
    # JSON-RPC bridge manually (see Section 7 fallback).
    ExMCP.Transport.HTTP.handle_request(conn, server: Mjolnir.MCP.Server)
  end
end
```

**Important**: Check `ex_mcp`'s actual HTTP transport API. If it doesn't expose a Plug-compatible handler, you'll need to bridge manually — accept the POST body as JSON-RPC, forward to the ExMCP server GenServer, and return the response. This is ~50 lines. See Section 7 for the fallback approach.

### 5.3 Router Integration

Update the existing `Mjolnir.API.Router` to forward `/mcp` requests, **or** configure Bandit with a dispatch that routes by path prefix:

```elixir
# Option A: Add to existing router (simplest)
# In lib/mjolnir/api/router.ex, before the catch-all match:

forward "/mcp", to: Mjolnir.MCP.Plug

# Option B: Top-level dispatch plug
defmodule Mjolnir.API.Dispatch do
  use Plug.Router

  plug :match
  plug :dispatch

  forward "/mcp", to: Mjolnir.MCP.Plug
  forward "/", to: Mjolnir.API.Router
end
```

Option A is simpler; Option B is cleaner if MCP auth diverges from REST auth.

### 5.4 Supervision Tree Update

```elixir
# In lib/mjolnir/application.ex, add before the Bandit child:

children = [
  # ... existing children ...
  {Mjolnir.MCP.Server, transport: :http, port: nil},  # no standalone port, served via Bandit
  {Bandit, plug: Mjolnir.API.Router, port: api_port}
]
```

The MCP server starts as a GenServer. It doesn't open its own port — Bandit handles all HTTP and the Plug adapter bridges into it.

## 6. Authentication

Reuse the existing `Mjolnir.API.Auth` plug. MCP requests to `/mcp` go through the same JWT/localhost-bypass pipeline as REST requests. The `Mcp-Session-Id` header is managed by `ex_mcp` internally.

For the MCP endpoint specifically:
- Localhost bypass works identically (dev/test)
- Bearer token in `Authorization` header (production)
- Same scopes: `vms:spawn`, `vms:exec`, etc.

No new auth code needed.

## 7. Fallback: Manual JSON-RPC Bridge

If `ex_mcp`'s HTTP transport doesn't integrate cleanly with Plug/Bandit, implement the bridge manually. The MCP Streamable HTTP protocol is simple:

```elixir
defmodule Mjolnir.MCP.Plug do
  import Plug.Conn

  def init(opts), do: opts

  def call(%{method: "POST"} = conn, _opts) do
    {:ok, body, conn} = read_body(conn)
    request = Jason.decode!(body)

    # Forward to ExMCP server and get response
    {:ok, response} = GenServer.call(
      Mjolnir.MCP.Server,
      {:jsonrpc, request}
    )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end

  def call(%{method: "GET"} = conn, _opts) do
    # SSE stream for server-initiated notifications
    conn
    |> put_resp_content_type("text/event-stream")
    |> send_chunked(200)
    |> stream_events()
  end
end
```

This is the escape hatch. Try the library integration first.

## 8. File Layout

```
lib/mjolnir/mcp/
├── server.ex       # ExMCP.Server with tool/resource definitions + handlers
└── plug.ex         # Plug adapter bridging Bandit ↔ ExMCP
```

Two files. That's it.

## 9. Implementation Steps

| # | Task | Detail |
|---|------|--------|
| 1 | Add `ex_mcp` dependency | `{:ex_mcp, "~> 0.7"}` in `mix.exs`, `mix deps.get` |
| 2 | Create `Mjolnir.MCP.Server` | `deftool` declarations + `handle_tool_call/3` for all 13 tools |
| 3 | Create `Mjolnir.MCP.Plug` | Plug adapter bridging Bandit → ExMCP HTTP transport |
| 4 | Wire into router | `forward "/mcp"` in existing router |
| 5 | Wire into supervision tree | Add `Mjolnir.MCP.Server` child in `application.ex` |
| 6 | Test with MCP Inspector | `npx @modelcontextprotocol/inspector http://localhost:4000/mcp` |
| 7 | Test with Claude/agent | Configure as MCP server in Claude Desktop or Cursor |

## 10. Tool Summary

13 tools mapping 1:1 with existing REST endpoints:

| MCP Tool | REST Endpoint | Delegates To |
|----------|--------------|--------------|
| `spawn_vm` | `POST /api/vms` | `Mjolnir.VM.spawn/1` |
| `list_vms` | `GET /api/vms` | `Mjolnir.VM.list/0` |
| `get_vm` | `GET /api/vms/:id` | `Mjolnir.VM.get/1` |
| `exec` | `POST /api/vms/:id/exec` | `Mjolnir.VM.exec/3` |
| `stop_vm` | `DELETE /api/vms/:id` | `Mjolnir.VM.stop/1` |
| `create_snapshot` | `POST /api/vms/:id/snapshots` | `Mjolnir.VM.snapshot/3` |
| `list_snapshots` | `GET /api/snapshots` | `Mjolnir.BTRFS.list_snapshots/0` |
| `get_snapshot` | `GET /api/snapshots/:name` | `Mjolnir.BTRFS.get_snapshot/1` |
| `delete_snapshot` | `DELETE /api/snapshots/:name` | `Mjolnir.BTRFS.delete_snapshot/1` |
| `deliver_message` | `POST /api/vms/:id/messages` | `Mjolnir.VM.deliver_message/3` |
| `get_connection_ticket` | `GET /api/vms/:id/ticket` | `Mjolnir.VM.connection_info/1` |
| `list_dormant` | `GET /api/dormant` | `Mjolnir.DormantRegistry.list/0` |
| `await_pty` | `POST /api/vms/:id/await-pty` | `Mjolnir.VM.await_pty/2` |

3 resources:

| Resource URI | Content |
|---|---|
| `mjolnir://vms` | All VMs with status |
| `mjolnir://snapshots` | All snapshots with metadata |
| `mjolnir://dormant` | Dormant VMs with pending message counts |

## 11. Testing

```bash
# Start Mjolnir with MCP enabled
iex -S mix

# In another terminal, test with MCP Inspector
npx @modelcontextprotocol/inspector http://localhost:4000/mcp

# Or curl the JSON-RPC directly
curl -X POST http://localhost:4000/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}'
```

## 12. Notes for Implementation Agent

- **Do NOT build a TypeScript sidecar.** Everything lives in Elixir on the BEAM.
- **Reuse `Mjolnir.API.Views`** for JSON rendering — same view functions the REST API uses.
- **Check `ex_mcp` HTTP transport docs** — the Plug integration may need adjustment based on how `ex_mcp` expects to receive HTTP requests. If it only supports standalone HTTP (its own port), you may need the manual JSON-RPC bridge from Section 7.
- **`String.to_existing_atom/1`** in `args_to_spawn_opts/1` is safe bc the atom keys already exist from the Mjolnir.VM module.
- **Error handling pattern**: Always return `{:ok, %{content: [...], is_error?: true}, state}` for business errors (not found, validation). Reserve `{:error, ...}` for protocol-level failures.
- The `@spawn_keys` list uses string keys bc MCP args arrive as string-keyed maps from JSON.
