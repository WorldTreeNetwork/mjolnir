defmodule Mjolnir.API.Router do
  @moduledoc """
  HTTP API for Mjolnir VM management.

  Endpoints:
    GET    /api/health        - Health check
    POST   /api/vms           - Spawn a new VM
    GET    /api/vms           - List all VMs
    GET    /api/vms/:id       - Get VM status
    POST   /api/vms/:id/exec  - Execute a command in a VM
    DELETE /api/vms/:id       - Stop a VM
  """

  use Plug.Router
  use Plug.ErrorHandler

  alias Mjolnir.API.Views

  plug(Plug.Logger)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  # Health check
  get "/api/health" do
    json(conn, 200, %{status: "ok"})
  end

  # Spawn a new VM
  post "/api/vms" do
    opts =
      conn.body_params
      |> Map.take(["base_image", "vcpus", "memory_mb"])
      |> atomize_keys()

    case Mjolnir.VM.spawn(opts) do
      {:ok, vm} ->
        json(conn, 201, %{vm: Views.vm_json(vm)})

      {:error, reason} ->
        json(conn, 500, %{error: inspect(reason)})
    end
  end

  # List all VMs
  get "/api/vms" do
    vms = Mjolnir.VM.list() |> Enum.map(&Views.vm_json/1)
    json(conn, 200, %{vms: vms})
  end

  # Get VM status
  get "/api/vms/:id" do
    case Mjolnir.VM.status(id) do
      {:error, :not_found} ->
        json(conn, 404, %{error: "not_found"})

      status ->
        json(conn, 200, %{id: id, status: status})
    end
  end

  # Execute command in a VM
  post "/api/vms/:id/exec" do
    command = conn.body_params["command"]

    if is_nil(command) or command == "" do
      json(conn, 400, %{error: "command is required"})
    else
      try do
        case Mjolnir.VM.exec(id, command) do
          {:ok, output} ->
            json(conn, 200, %{output: output})

          {:error, {:exit_code, code, stderr}} ->
            json(conn, 200, %{exit_code: code, stderr: stderr})

          {:error, reason} ->
            json(conn, 500, %{error: inspect(reason)})
        end
      catch
        :exit, {:noproc, _} ->
          json(conn, 404, %{error: "not_found"})
      end
    end
  end

  # Stop a VM
  delete "/api/vms/:id" do
    case Mjolnir.VM.stop(id) do
      :ok ->
        json(conn, 200, %{status: "stopped"})

      {:error, :not_found} ->
        json(conn, 404, %{error: "not_found"})

      {:error, reason} ->
        json(conn, 500, %{error: inspect(reason)})
    end
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: _kind, reason: reason, stack: _stack}) do
    json(conn, 500, %{error: inspect(reason)})
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp atomize_keys(map) do
    allowed = %{"base_image" => :base_image, "vcpus" => :vcpus, "memory_mb" => :memory_mb}

    Map.new(map, fn {k, v} ->
      case Map.fetch(allowed, k) do
        {:ok, atom_key} -> {atom_key, v}
        :error -> {k, v}
      end
    end)
  end
end
