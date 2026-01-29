defmodule Mjolnir.DebugServer do
  @moduledoc """
  Simple TCP debug server for remote control of Mjolnir.

  Listens on localhost:9999 by default. Accepts JSON commands, returns JSON responses.

  ## Commands

  - `{"cmd": "spawn"}` - Spawn a new VM
  - `{"cmd": "exec", "vm_id": "...", "command": "..."}` - Execute command in VM
  - `{"cmd": "stop", "vm_id": "..."}` - Stop a VM
  - `{"cmd": "list"}` - List all running VMs
  - `{"cmd": "await_shell", "vm_id": "...", "timeout": 30000}` - Wait for shell ready
  - `{"cmd": "status", "vm_id": "..."}` - Get VM status

  ## Usage

      # Spawn a VM
      echo '{"cmd":"spawn"}' | nc localhost 9999

      # Execute command
      echo '{"cmd":"exec","vm_id":"abc123","command":"uname -a"}' | nc localhost 9999

      # Or with curl (using netcat mode)
      curl -s localhost:9999 -d '{"cmd":"list"}'
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
        Logger.info("Debug server listening on localhost:#{port}")
        # Start acceptor
        send(self(), :accept)
        {:ok, %{listen_socket: listen_socket, port: port}}

      {:error, reason} ->
        Logger.error("Failed to start debug server: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    # Accept in a task to not block
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
