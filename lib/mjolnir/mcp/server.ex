defmodule Mjolnir.MCP.Server do
  @moduledoc """
  MCP (Model Context Protocol) server for Mjolnir VM management.

  Exposes Mjolnir's VM lifecycle operations as MCP tools, allowing
  AI agents to discover and invoke VM operations via the standard
  MCP protocol.
  """

  use ExMCP.Server.Handler
  use ExMCP.Server.DSL, name: "mjolnir", version: "0.1.0"

  alias Mjolnir.MCP.Authorization

  @impl GenServer
  def init(context) when is_map(context), do: {:ok, context}
  def init(_), do: {:ok, %{}}

  # ── Tools ──────────────────────────────────────────────

  tool "spawn_vm" do
    title("Spawn VM")
    description("Create and boot a new microVM. Returns the VM's UUID and status.")

    input_schema(%{
      type: "object",
      properties: %{
        base_image: %{
          type: "string",
          description: "Base rootfs image name (e.g. 'ubuntu-24.04')."
        },
        memory_mb: %{
          type: "integer",
          minimum: 128,
          maximum: 8192,
          description: "RAM in MB. Default: 512."
        },
        vcpus: %{
          type: "integer",
          minimum: 1,
          maximum: 8,
          description: "Virtual CPUs. Default: 1."
        },
        ssh_public_key: %{type: "string", description: "SSH public key to inject."},
        snapshot: %{
          type: "string",
          description: "Restore from named snapshot instead of fresh base."
        },
        enable_iroh: %{type: "boolean", description: "Enable Iroh P2P networking."},
        owner_id: %{
          type: "string",
          description:
            "Canonical base58 XID. Required when the caller is the operator. Ignored for a signed-in account."
        }
      }
    })

    run(fn args, state -> dispatch_tool("spawn_vm", args, state) end)
  end

  tool "list_vms" do
    title("List VMs")
    description("List all running microVMs with state and connectivity info.")

    input_schema(%{type: "object", properties: %{}})

    run(fn args, state -> dispatch_tool("list_vms", args, state) end)
  end

  tool "get_vm" do
    title("Get VM")
    description("Get detailed info about a specific VM.")

    input_schema(%{
      type: "object",
      properties: %{vm_id: %{type: "string", description: "UUID of the target VM."}},
      required: ["vm_id"]
    })

    run(fn args, state -> dispatch_tool("get_vm", args, state) end)
  end

  tool "exec" do
    title("Execute Command")

    description(
      "Execute a shell command inside a running VM. Returns stdout, stderr, and exit code."
    )

    input_schema(%{
      type: "object",
      properties: %{
        vm_id: %{type: "string", description: "UUID of the target VM."},
        command: %{type: "string", description: "Shell command to execute."},
        timeout: %{
          type: "integer",
          minimum: 1000,
          maximum: 300_000,
          description: "Timeout in ms. Default: 30000."
        }
      },
      required: ["vm_id", "command"]
    })

    run(fn args, state -> dispatch_tool("exec", args, state) end)
  end

  tool "stop_vm" do
    title("Stop VM")
    description("Stop and destroy a running VM. Irreversible.")

    input_schema(%{
      type: "object",
      properties: %{vm_id: %{type: "string", description: "UUID of the VM to stop."}},
      required: ["vm_id"]
    })

    run(fn args, state -> dispatch_tool("stop_vm", args, state) end)
  end

  tool "create_snapshot" do
    title("Create Snapshot")
    description("Snapshot a running VM's filesystem via BTRFS CoW.")

    input_schema(%{
      type: "object",
      properties: %{
        vm_id: %{type: "string", description: "UUID of the VM to snapshot."},
        name: %{type: "string", description: "Unique name for this snapshot."}
      },
      required: ["vm_id", "name"]
    })

    run(fn args, state -> dispatch_tool("create_snapshot", args, state) end)
  end

  tool "list_snapshots" do
    title("List Snapshots")
    description("List all available snapshots.")

    input_schema(%{type: "object", properties: %{}})

    run(fn args, state -> dispatch_tool("list_snapshots", args, state) end)
  end

  tool "get_snapshot" do
    title("Get Snapshot")
    description("Get metadata for a specific snapshot.")

    input_schema(%{
      type: "object",
      properties: %{name: %{type: "string", description: "Snapshot name."}},
      required: ["name"]
    })

    run(fn args, state -> dispatch_tool("get_snapshot", args, state) end)
  end

  tool "delete_snapshot" do
    title("Delete Snapshot")
    description("Permanently delete a snapshot.")

    input_schema(%{
      type: "object",
      properties: %{name: %{type: "string", description: "Snapshot name to delete."}},
      required: ["name"]
    })

    run(fn args, state -> dispatch_tool("delete_snapshot", args, state) end)
  end

  tool "deliver_message" do
    title("Deliver Message")
    description("Send a message to a VM for inter-VM communication or coroutine wake-up.")

    input_schema(%{
      type: "object",
      properties: %{
        vm_id: %{type: "string", description: "Target VM UUID."},
        from_vm_id: %{type: "string", description: "Source VM UUID or 'external'."},
        id: %{
          type: "string",
          description: "Producer message id. Same id retried is a duplicate."
        },
        payload: %{type: "object", description: "Arbitrary JSON payload."}
      },
      required: ["vm_id"]
    })

    run(fn args, state -> dispatch_tool("deliver_message", args, state) end)
  end

  tool "get_connection_ticket" do
    title("Get Connection Ticket")
    description("Get an Iroh connection ticket for P2P shell access.")

    input_schema(%{
      type: "object",
      properties: %{vm_id: %{type: "string", description: "UUID of the VM."}},
      required: ["vm_id"]
    })

    run(fn args, state -> dispatch_tool("get_connection_ticket", args, state) end)
  end

  tool "list_dormant" do
    title("List Dormant VMs")
    description("List VMs snapshotted and stopped, awaiting messages to restore.")

    input_schema(%{type: "object", properties: %{}})

    run(fn args, state -> dispatch_tool("list_dormant", args, state) end)
  end

  tool "await_pty" do
    title("Await PTY")
    description("Wait for VM PTY/shell readiness. Returns connection ticket.")

    input_schema(%{
      type: "object",
      properties: %{
        vm_id: %{type: "string", description: "UUID of the VM."},
        timeout: %{type: "integer", minimum: 1000, description: "Timeout in ms. Default: 30000."}
      },
      required: ["vm_id"]
    })

    run(fn args, state -> dispatch_tool("await_pty", args, state) end)
  end

  # ── Resources ──────────────────────────────────────────

  resource "mjolnir://vms" do
    name("VM List")
    description("All running VMs with status summary")

    mime_type("application/json")

    read(fn %{uri: uri}, state -> read_resource(uri, state) end)
  end

  resource "mjolnir://snapshots" do
    name("Snapshot List")
    description("All available snapshots with metadata")

    mime_type("application/json")

    read(fn %{uri: uri}, state -> read_resource(uri, state) end)
  end

  resource "mjolnir://dormant" do
    name("Dormant VMs")
    description("Dormant VMs with pending message counts")

    mime_type("application/json")

    read(fn %{uri: uri}, state -> read_resource(uri, state) end)
  end

  # ── Tool Handlers ──────────────────────────────────────

  def handle_tool_call("spawn_vm", args, state) do
    case Mjolnir.Deploy.Owner.resolve(state[:user_id], args["owner_id"]) do
      {:error, reason} ->
        {:ok, %{content: [text("Spawn refused: #{reason}")], isError: true}, state}

      {:ok, owner_id} ->
        opts = args_to_spawn_opts(args) |> Map.put(:owner_id, owner_id)

        case Mjolnir.VM.spawn(opts) do
          {:ok, vm} ->
            {:ok, %{content: [text(Jason.encode!(Mjolnir.API.Views.render_vm(vm)))]}, state}

          {:error, reason} ->
            {:ok, %{content: [text("Spawn failed: #{inspect(reason)}")], isError: true}, state}
        end
    end
  end

  def handle_tool_call("list_vms", _args, state) do
    vms =
      Mjolnir.VM.list()
      |> Enum.filter(&Authorization.visible?(state, &1))
      |> Enum.map(&Mjolnir.API.Views.render_vm_summary/1)

    {:ok, %{content: [text(Jason.encode!(%{vms: vms}))]}, state}
  end

  def handle_tool_call("get_vm", %{"vm_id" => id}, state) do
    case Mjolnir.VM.get(id) do
      {:ok, vm} ->
        {:ok, %{content: [text(Jason.encode!(Mjolnir.API.Views.render_vm(vm)))]}, state}

      {:error, :not_found} ->
        {:ok, %{content: [text("VM not found: #{id}")], isError: true}, state}

      # Registered but wedged (mjolnir-8ie): distinguish from "gone" so callers
      # don't treat an unreachable VM as destroyed.
      {:error, :unreachable} ->
        {:ok, %{content: [text("VM unreachable: #{id}")], isError: true}, state}
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
        {:ok, %{content: [text("VM not found: #{id}")], isError: true}, state}

      {:error, reason} ->
        {:ok, %{content: [text("Exec failed: #{inspect(reason)}")], isError: true}, state}
    end
  end

  def handle_tool_call("stop_vm", %{"vm_id" => id}, state) do
    case Mjolnir.VM.stop(id) do
      :ok ->
        {:ok, %{content: [text(~s({"ok": true}))]}, state}

      {:error, :not_found} ->
        {:ok, %{content: [text("VM not found: #{id}")], isError: true}, state}

      {:error, reason} ->
        {:ok, %{content: [text("Stop failed: #{inspect(reason)}")], isError: true}, state}
    end
  end

  def handle_tool_call("create_snapshot", %{"vm_id" => id, "name" => name}, state) do
    case Mjolnir.VM.snapshot(id, name) do
      {:ok, metadata} ->
        {:ok, %{content: [text(Jason.encode!(metadata))]}, state}

      {:error, {:snapshot_exists, _}} ->
        {:ok, %{content: [text("Snapshot '#{name}' already exists")], isError: true}, state}

      {:error, :not_found} ->
        {:ok, %{content: [text("VM not found: #{id}")], isError: true}, state}

      {:error, reason} ->
        {:ok, %{content: [text("Snapshot failed: #{inspect(reason)}")], isError: true}, state}
    end
  end

  def handle_tool_call("list_snapshots", _args, state) do
    case Mjolnir.BTRFS.list_snapshots() do
      {:ok, snapshots} ->
        snapshots = Enum.filter(snapshots, &Authorization.visible?(state, &1))
        {:ok, %{content: [text(Jason.encode!(%{snapshots: snapshots}))]}, state}

      {:error, reason} ->
        {:ok, %{content: [text("Failed: #{inspect(reason)}")], isError: true}, state}
    end
  end

  def handle_tool_call("get_snapshot", %{"name" => name}, state) do
    case Mjolnir.BTRFS.get_snapshot(name) do
      {:ok, %{metadata: metadata}} ->
        {:ok, %{content: [text(Jason.encode!(metadata))]}, state}

      {:error, {:snapshot_not_found, _}} ->
        {:ok, %{content: [text("Snapshot not found: #{name}")], isError: true}, state}

      {:error, reason} ->
        {:ok, %{content: [text("Failed: #{inspect(reason)}")], isError: true}, state}
    end
  end

  def handle_tool_call("delete_snapshot", %{"name" => name}, state) do
    case Mjolnir.BTRFS.delete_snapshot(name) do
      :ok ->
        {:ok, %{content: [text(~s({"ok": true}))]}, state}

      {:error, {:snapshot_not_found, _}} ->
        {:ok, %{content: [text("Snapshot not found: #{name}")], isError: true}, state}

      {:error, reason} ->
        {:ok, %{content: [text("Failed: #{inspect(reason)}")], isError: true}, state}
    end
  end

  def handle_tool_call("deliver_message", %{"vm_id" => id} = args, state) do
    from = Map.get(args, "from_vm_id", "external")
    payload = Map.get(args, "payload", %{})
    opts = if args["id"], do: [id: args["id"]], else: []

    case Mjolnir.VM.deliver_message(id, from, payload, opts) do
      {:ok, %{message_id: mid, status: status}} ->
        body = Jason.encode!(%{ok: true, message_id: mid, status: status})
        {:ok, %{content: [text(body)]}, state}

      {:error, :not_found} ->
        {:ok, %{content: [text("VM not found: #{id}")], isError: true}, state}

      {:error, reason} ->
        {:ok, %{content: [text("Failed: #{inspect(reason)}")], isError: true}, state}
    end
  end

  def handle_tool_call("get_connection_ticket", %{"vm_id" => id}, state) do
    case Mjolnir.VM.connection_info(id) do
      {:ok, ticket, iroh_addr} ->
        {:ok, %{content: [text(Jason.encode!(%{ticket: ticket, iroh_addr: iroh_addr}))]}, state}

      {:error, :not_ready} ->
        {:ok,
         %{content: [text("VM not ready — Iroh endpoint still initializing")], isError: true},
         state}

      {:error, :not_found} ->
        {:ok, %{content: [text("VM not found: #{id}")], isError: true}, state}
    end
  end

  def handle_tool_call("list_dormant", _args, state) do
    dormant =
      Mjolnir.DormantRegistry.list()
      |> Enum.filter(&Authorization.visible?(state, &1))
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
        {:ok, %{content: [text("Timed out waiting for PTY readiness")], isError: true}, state}

      {:error, :not_found} ->
        {:ok, %{content: [text("VM not found: #{id}")], isError: true}, state}
    end
  end

  # ── Resource Handlers ──────────────────────────────────

  def handle_resource_read("mjolnir://vms", _uri, state) do
    vms =
      Mjolnir.VM.list()
      |> Enum.filter(&Authorization.visible?(state, &1))
      |> Enum.map(&Mjolnir.API.Views.render_vm_summary/1)

    {:ok, [json(%{vms: vms})], state}
  end

  def handle_resource_read("mjolnir://snapshots", _uri, state) do
    case Mjolnir.BTRFS.list_snapshots() do
      {:ok, snapshots} ->
        {:ok, [json(%{snapshots: Enum.filter(snapshots, &Authorization.visible?(state, &1))})],
         state}

      {:error, reason} ->
        {:error, inspect(reason), state}
    end
  end

  def handle_resource_read("mjolnir://dormant", _uri, state) do
    dormant =
      Mjolnir.DormantRegistry.list()
      |> Enum.filter(&Authorization.visible?(state, &1))
      |> Enum.map(fn e ->
        %{
          vm_id: e.vm_id,
          snapshot_name: e.snapshot_name,
          pending_messages: length(e.pending_messages)
        }
      end)

    {:ok, [json(%{dormant: dormant})], state}
  end

  defp dispatch_tool(name, args, state) do
    case Authorization.authorize_tool(state, name, args) do
      :ok -> handle_tool_call(name, args, state)
      {:error, reason} -> {:ok, %{content: [text(reason)], isError: true}, state}
    end
  end

  defp read_resource(uri, state) do
    with :ok <- Authorization.authorize_resource(state, uri),
         {:ok, contents, next_state} <- handle_resource_read(uri, uri, state) do
      contents =
        Enum.map(contents, fn item ->
          %{uri: uri, mimeType: "application/json", text: item["text"]}
        end)

      {:ok, contents, next_state}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, reason, next_state} -> {:error, reason, next_state}
    end
  end

  defp text(value), do: %{"type" => "text", "text" => value}
  defp json(value), do: text(Jason.encode!(value))

  # ── Helpers ────────────────────────────────────────────

  @spawn_keys ~w(base_image memory_mb vcpus ssh_public_key snapshot enable_iroh)

  defp args_to_spawn_opts(args) do
    args
    |> Map.take(@spawn_keys)
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      Map.put(acc, String.to_existing_atom(k), v)
    end)
  end
end
