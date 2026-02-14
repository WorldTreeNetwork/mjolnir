defmodule Mjolnir.API.Router do
  @moduledoc """
  HTTP API router for Mjolnir VM management.

  Provides RESTful endpoints for spawning, listing, inspecting,
  executing commands in, and stopping microVMs. Authentication is
  handled by `Mjolnir.API.Auth` (JWT or localhost bypass).
  """

  use Plug.Router

  import Mjolnir.API.Authz
  alias Mjolnir.API.Views

  plug(Plug.Logger)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(Mjolnir.API.Auth)
  plug(:match)
  plug(:dispatch)

  # Health check — no auth required (skipped by Auth plug)
  get "/api/health" do
    json(conn, 200, %{status: "ok"})
  end

  # Spawn a new VM
  post "/api/vms" do
    conn = require_scope(conn, "vms:spawn")

    unless conn.halted do
      opts = %{}

      opts =
        if conn.body_params["base_image"],
          do: Map.put(opts, :base_image, conn.body_params["base_image"]),
          else: opts

      opts =
        if conn.body_params["memory_mb"],
          do: Map.put(opts, :memory_mb, conn.body_params["memory_mb"]),
          else: opts

      opts =
        if conn.body_params["vcpus"],
          do: Map.put(opts, :vcpus, conn.body_params["vcpus"]),
          else: opts

      opts =
        if conn.body_params["ssh_public_key"],
          do: Map.put(opts, :ssh_public_key, conn.body_params["ssh_public_key"]),
          else: opts

      opts =
        if conn.body_params["snapshot"],
          do: Map.put(opts, :snapshot, conn.body_params["snapshot"]),
          else: opts

      opts =
        if conn.body_params["rootfs_size_mb"],
          do: Map.put(opts, :rootfs_size_mb, conn.body_params["rootfs_size_mb"]),
          else: opts

      case Mjolnir.VM.spawn(opts) do
        {:ok, vm} ->
          json(conn, 201, Views.render_vm(vm))

        {:error, reason} ->
          json(conn, 500, %{error: inspect(reason)})
      end
    else
      conn
    end
  end

  # List all VMs
  get "/api/vms" do
    conn = require_scope(conn, "vms:read")

    unless conn.halted do
      vms = Mjolnir.VM.list() |> Enum.map(&Views.render_vm_summary/1)
      json(conn, 200, %{vms: vms})
    else
      conn
    end
  end

  # Get VM details
  get "/api/vms/:id" do
    conn = require_scope(conn, "vms:read")

    unless conn.halted do
      case Mjolnir.VM.get(id) do
        {:ok, vm} ->
          json(conn, 200, Views.render_vm(vm))

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})
      end
    else
      conn
    end
  end

  # Execute command in VM
  post "/api/vms/:id/exec" do
    conn = require_scope(conn, "vms:exec")

    unless conn.halted do
      command = conn.body_params["command"]
      timeout = conn.body_params["timeout"] || 30_000

      case Mjolnir.VM.exec(id, command, timeout: timeout) do
        {:ok, output} ->
          json(conn, 200, %{output: output})

        {:error, {:exit_code, code, stderr}} ->
          json(conn, 200, %{exit_code: code, stderr: stderr})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, reason} ->
          json(conn, 500, %{error: inspect(reason)})
      end
    else
      conn
    end
  end

  # Stop VM
  delete "/api/vms/:id" do
    conn = require_scope(conn, "vms:stop")

    unless conn.halted do
      case Mjolnir.VM.stop(id) do
        :ok ->
          json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, reason} ->
          json(conn, 500, %{error: inspect(reason)})
      end
    else
      conn
    end
  end

  # Get connection ticket (compact base58 + full iroh JSON for interop)
  get "/api/vms/:id/ticket" do
    conn = require_scope(conn, "shell:connect")

    unless conn.halted do
      case Mjolnir.VM.connection_info(id) do
        {:ok, ticket, iroh_addr} ->
          json(conn, 200, %{ticket: ticket, iroh_addr: iroh_addr})

        {:error, :not_ready} ->
          json(conn, 503, %{error: "not_ready"})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})
      end
    else
      conn
    end
  end

  # Await shell readiness, returns compact ticket
  post "/api/vms/:id/await-shell" do
    conn = require_scope(conn, "shell:connect")

    unless conn.halted do
      timeout = conn.body_params["timeout"] || 30_000

      case Mjolnir.VM.await_shell(id, timeout) do
        {:ok, ticket} ->
          json(conn, 200, %{ticket: ticket})

        {:error, :timeout} ->
          json(conn, 504, %{error: "timeout"})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})
      end
    else
      conn
    end
  end

  # Create snapshot of a VM
  post "/api/vms/:id/snapshots" do
    conn = require_scope(conn, "snapshots:create")

    unless conn.halted do
      name = conn.body_params["name"]

      if is_nil(name) or name == "" do
        json(conn, 400, %{error: "name is required"})
      else
        compact = conn.body_params["compact"] || false

        case Mjolnir.VM.snapshot(id, name, compact: compact) do
          {:ok, metadata} ->
            json(conn, 201, metadata)

          {:error, {:snapshot_exists, _}} ->
            json(conn, 409, %{error: "snapshot already exists"})

          {:error, :not_found} ->
            json(conn, 404, %{error: "vm not_found"})

          {:error, reason} ->
            json(conn, 500, %{error: inspect(reason)})
        end
      end
    else
      conn
    end
  end

  # List all snapshots
  get "/api/snapshots" do
    conn = require_scope(conn, "snapshots:read")

    unless conn.halted do
      case Mjolnir.BTRFS.list_snapshots() do
        {:ok, snapshots} ->
          json(conn, 200, %{snapshots: snapshots})

        {:error, reason} ->
          json(conn, 500, %{error: inspect(reason)})
      end
    else
      conn
    end
  end

  # Get snapshot metadata
  get "/api/snapshots/:name" do
    conn = require_scope(conn, "snapshots:read")

    unless conn.halted do
      case Mjolnir.BTRFS.get_snapshot(name) do
        {:ok, %{metadata: metadata}} ->
          json(conn, 200, metadata)

        {:error, {:snapshot_not_found, _}} ->
          json(conn, 404, %{error: "not_found"})

        {:error, reason} ->
          json(conn, 500, %{error: inspect(reason)})
      end
    else
      conn
    end
  end

  # Delete a snapshot
  delete "/api/snapshots/:name" do
    conn = require_scope(conn, "snapshots:delete")

    unless conn.halted do
      case Mjolnir.BTRFS.delete_snapshot(name) do
        :ok ->
          json(conn, 200, %{ok: true})

        {:error, {:snapshot_not_found, _}} ->
          json(conn, 404, %{error: "not_found"})

        {:error, reason} ->
          json(conn, 500, %{error: inspect(reason)})
      end
    else
      conn
    end
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
