defmodule Mjolnir.MCP.Server do
  @moduledoc """
  MCP (Model Context Protocol) server for Mjolnir VM management.

  Exposes Mjolnir's VM lifecycle operations as MCP tools, allowing
  AI agents to discover and invoke VM operations via the standard
  MCP protocol.
  """

  use ExMCP.Server

  # ── Tools ──────────────────────────────────────────────

  deftool "spawn_vm" do
    meta do
      name("Spawn VM")
      description("Create and boot a new microVM. Returns the VM's UUID and status.")
    end

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
        enable_iroh: %{type: "boolean", description: "Enable Iroh P2P networking."}
      }
    })
  end

  deftool "list_vms" do
    meta do
      name("List VMs")
      description("List all running microVMs with state and connectivity info.")
    end

    input_schema(%{type: "object", properties: %{}})
  end

  deftool "get_vm" do
    meta do
      name("Get VM")
      description("Get detailed info about a specific VM.")
    end

    input_schema(%{
      type: "object",
      properties: %{vm_id: %{type: "string", description: "UUID of the target VM."}},
      required: ["vm_id"]
    })
  end

  deftool "exec" do
    meta do
      name("Execute Command")

      description(
        "Execute a shell command inside a running VM. Returns stdout, stderr, and exit code."
      )
    end

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
  end

  deftool "stop_vm" do
    meta do
      name("Stop VM")
      description("Stop and destroy a running VM. Irreversible.")
    end

    input_schema(%{
      type: "object",
      properties: %{vm_id: %{type: "string", description: "UUID of the VM to stop."}},
      required: ["vm_id"]
    })
  end

  deftool "create_snapshot" do
    meta do
      name("Create Snapshot")
      description("Snapshot a running VM's filesystem via BTRFS CoW.")
    end

    input_schema(%{
      type: "object",
      properties: %{
        vm_id: %{type: "string", description: "UUID of the VM to snapshot."},
        name: %{type: "string", description: "Unique name for this snapshot."}
      },
      required: ["vm_id", "name"]
    })
  end

  deftool "list_snapshots" do
    meta do
      name("List Snapshots")
      description("List all available snapshots.")
    end

    input_schema(%{type: "object", properties: %{}})
  end

  deftool "get_snapshot" do
    meta do
      name("Get Snapshot")
      description("Get metadata for a specific snapshot.")
    end

    input_schema(%{
      type: "object",
      properties: %{name: %{type: "string", description: "Snapshot name."}},
      required: ["name"]
    })
  end

  deftool "delete_snapshot" do
    meta do
      name("Delete Snapshot")
      description("Permanently delete a snapshot.")
    end

    input_schema(%{
      type: "object",
      properties: %{name: %{type: "string", description: "Snapshot name to delete."}},
      required: ["name"]
    })
  end

  deftool "deliver_message" do
    meta do
      name("Deliver Message")
      description("Send a message to a VM for inter-VM communication or coroutine wake-up.")
    end

    input_schema(%{
      type: "object",
      properties: %{
        vm_id: %{type: "string", description: "Target VM UUID."},
        from_vm_id: %{type: "string", description: "Source VM UUID or 'external'."},
        payload: %{type: "object", description: "Arbitrary JSON payload."}
      },
      required: ["vm_id"]
    })
  end

  deftool "get_connection_ticket" do
    meta do
      name("Get Connection Ticket")
      description("Get an Iroh connection ticket for P2P shell access.")
    end

    input_schema(%{
      type: "object",
      properties: %{vm_id: %{type: "string", description: "UUID of the VM."}},
      required: ["vm_id"]
    })
  end

  deftool "list_dormant" do
    meta do
      name("List Dormant VMs")
      description("List VMs snapshotted and stopped, awaiting messages to restore.")
    end

    input_schema(%{type: "object", properties: %{}})
  end

  deftool "await_pty" do
    meta do
      name("Await PTY")
      description("Wait for VM PTY/shell readiness. Returns connection ticket.")
    end

    input_schema(%{
      type: "object",
      properties: %{
        vm_id: %{type: "string", description: "UUID of the VM."},
        timeout: %{type: "integer", minimum: 1000, description: "Timeout in ms. Default: 30000."}
      },
      required: ["vm_id"]
    })
  end

  # ── Resources ──────────────────────────────────────────

  defresource "mjolnir://vms" do
    meta do
      name("VM List")
      description("All running VMs with status summary")
    end

    mime_type("application/json")
  end

  defresource "mjolnir://snapshots" do
    meta do
      name("Snapshot List")
      description("All available snapshots with metadata")
    end

    mime_type("application/json")
  end

  defresource "mjolnir://dormant" do
    meta do
      name("Dormant VMs")
      description("Dormant VMs with pending message counts")
    end

    mime_type("application/json")
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

  def handle_tool_call("create_snapshot", %{"vm_id" => id, "name" => name}, state) do
    case Mjolnir.VM.snapshot(id, name) do
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
        {:ok,
         %{content: [text("VM not ready — Iroh endpoint still initializing")], is_error?: true},
         state}

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
        %{
          vm_id: e.vm_id,
          snapshot_name: e.snapshot_name,
          pending_messages: length(e.pending_messages)
        }
      end)

    {:ok, [json(%{dormant: dormant})], state}
  end

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
