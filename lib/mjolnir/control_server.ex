defmodule Mjolnir.ControlServer do
  @moduledoc """
  TCP control server for Mjolnir Orchestrator.

  Provides a JSON-over-TCP interface for managing MicroVMs. Listens on
  localhost:9999 by default. Useful for CLI tools, scripts, and AI agents.

  ## Commands

  All commands are JSON objects with a `cmd` field. Responses are JSON with an `ok` boolean.

  | Command | Parameters | Description |
  |---------|------------|-------------|
  | `spawn` | `base_image`, `memory_mb`, `vcpus` (all optional) | Spawn a new VM |
  | `exec` | `vm_id`, `command` | Execute shell command in VM |
  | `stop` | `vm_id` | Stop and cleanup VM |
  | `list` | - | List all running VMs |
  | `status` | `vm_id` | Get VM status |
  | `await_shell` | `vm_id`, `timeout` (optional, default 30000ms) | Wait for Iroh shell ready |
  | `get_ticket` | `vm_id` | Get Iroh connection ticket |

  ## Examples

      # Spawn a VM
      echo '{"cmd":"spawn"}' | nc -q1 localhost 9999 | jq .

      # Execute command
      echo '{"cmd":"exec","vm_id":"abc123","command":"uname -a"}' | nc -q1 localhost 9999

      # List VMs
      echo '{"cmd":"list"}' | nc -q1 localhost 9999 | jq .

      # Stop VM
      echo '{"cmd":"stop","vm_id":"abc123"}' | nc -q1 localhost 9999

  ## Response Format

      # Success
      {"ok": true, "vm_id": "...", ...}

      # Error
      {"ok": false, "error": "reason"}

  ## Configuration

  The port can be configured in `config/config.exs`:

      config :mjolnir, Mjolnir.ControlServer, port: 9999
  """

  use GenServer
  require Logger

  @default_port 9999

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)

    case :gen_tcp.listen(port, [
           :binary,
           packet: :line,
           active: false,
           reuseaddr: true,
           ip: {127, 0, 0, 1}
         ]) do
      {:ok, listen_socket} ->
        Logger.info("Mjolnir control server listening on localhost:#{port}")
        send(self(), :accept)
        {:ok, %{listen_socket: listen_socket, port: port}}

      {:error, reason} ->
        Logger.error("Failed to start control server: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    Task.start(fn -> accept_loop(state.listen_socket) end)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client} ->
        handle_client(client)
        accept_loop(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.error("Accept error: #{inspect(reason)}")
        accept_loop(listen_socket)
    end
  end

  defp handle_client(socket) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, data} ->
        response = process_command(String.trim(data))
        :gen_tcp.send(socket, response <> "\n")
        :gen_tcp.close(socket)

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end
  end

  defp process_command(json) do
    case Jason.decode(json) do
      {:ok, cmd} ->
        result = execute_command(cmd)
        Jason.encode!(result)

      {:error, _} ->
        Jason.encode!(%{error: "invalid_json", message: "Could not parse JSON"})
    end
  end

  defp execute_command(%{"cmd" => "spawn"} = cmd) do
    opts = %{}
    opts = if cmd["base_image"], do: Map.put(opts, :base_image, cmd["base_image"]), else: opts
    opts = if cmd["memory_mb"], do: Map.put(opts, :memory_mb, cmd["memory_mb"]), else: opts
    opts = if cmd["vcpus"], do: Map.put(opts, :vcpus, cmd["vcpus"]), else: opts

    case Mjolnir.VM.spawn(opts) do
      {:ok, vm} ->
        %{
          ok: true,
          vm_id: vm.id,
          guest_ip: vm.net_config[:guest_ip],
          shell_ready: vm.shell_ready,
          iroh_node_id: vm.iroh_node_id,
          iroh_ticket: vm.iroh_ticket
        }

      {:error, reason} ->
        %{ok: false, error: inspect(reason)}
    end
  end

  defp execute_command(%{"cmd" => "exec", "vm_id" => vm_id, "command" => command}) do
    timeout = 30_000

    case Mjolnir.VM.exec(vm_id, command, timeout: timeout) do
      {:ok, output} ->
        %{ok: true, output: output}

      {:error, {:exit_code, code, stderr}} ->
        %{ok: false, exit_code: code, stderr: stderr}

      {:error, reason} ->
        %{ok: false, error: inspect(reason)}
    end
  end

  defp execute_command(%{"cmd" => "stop", "vm_id" => vm_id}) do
    case Mjolnir.VM.stop(vm_id) do
      :ok -> %{ok: true}
      {:error, reason} -> %{ok: false, error: inspect(reason)}
    end
  end

  defp execute_command(%{"cmd" => "list"}) do
    vms =
      Mjolnir.VM.list()
      |> Enum.map(fn vm ->
        %{
          vm_id: vm.id,
          state: vm.state,
          guest_ip: vm.net_config[:guest_ip],
          shell_ready: vm.shell_ready,
          iroh_node_id: vm.iroh_node_id
        }
      end)

    %{ok: true, vms: vms}
  end

  defp execute_command(%{"cmd" => "status", "vm_id" => vm_id}) do
    case Mjolnir.VM.status(vm_id) do
      {:error, :not_found} ->
        %{ok: false, error: "not_found"}

      status ->
        %{ok: true, status: status}
    end
  end

  defp execute_command(%{"cmd" => "await_shell", "vm_id" => vm_id} = cmd) do
    timeout = cmd["timeout"] || 30_000

    case Mjolnir.VM.await_shell(vm_id, timeout) do
      {:ok, ticket} ->
        %{ok: true, ticket: ticket}

      {:error, :timeout} ->
        %{ok: false, error: "timeout"}

      {:error, :not_found} ->
        %{ok: false, error: "not_found"}
    end
  end

  defp execute_command(%{"cmd" => "get_ticket", "vm_id" => vm_id}) do
    case Mjolnir.VM.get_ticket(vm_id) do
      {:ok, ticket} -> %{ok: true, ticket: ticket}
      {:error, reason} -> %{ok: false, error: inspect(reason)}
    end
  end

  defp execute_command(%{"cmd" => cmd}) do
    %{ok: false, error: "unknown_command", command: cmd}
  end

  defp execute_command(_) do
    %{ok: false, error: "missing_cmd", message: "Request must include 'cmd' field"}
  end
end
