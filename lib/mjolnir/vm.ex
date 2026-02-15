defmodule Mjolnir.VM do
  @moduledoc """
  MicroVM lifecycle management.

  Spawns Firecracker VMs with BTRFS-backed filesystems and provides
  command execution via serial console.
  """

  use GenServer, restart: :transient
  require Logger

  alias Mjolnir.Firecracker.{Client, Config}
  alias Mjolnir.BTRFS

  defstruct [
    :id,
    :config,
    :firecracker_pid,
    :firecracker_port,
    :socket_path,
    :vsock_path,
    :serial_path,
    :rootfs_path,
    :net_config,
    :state,
    :boot_time,
    # Iroh shell support
    :iroh_node_id,
    :iroh_json,
    :ticket,
    :shell_ready,
    # SSH key injection
    :ssh_public_key
  ]

  @type t :: %__MODULE__{}
  @type vm_id :: String.t()
  @type spawn_opts :: %{
          optional(:base_image) => String.t(),
          optional(:vcpus) => pos_integer(),
          optional(:memory_mb) => pos_integer(),
          optional(:ssh_public_key) => String.t(),
          optional(:snapshot) => String.t(),
          optional(:rootfs_size_mb) => pos_integer(),
          optional(:preserve_iroh_key) => boolean()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Spawn a new MicroVM.

  ## Options

  - `:base_image` - Base image name (default: "ubuntu-24.04")
  - `:vcpus` - Number of vCPUs (default: 2)
  - `:memory_mb` - Memory in MiB (default: 512)
  - `:snapshot` - Snapshot name to spawn from (instead of base image)
  - `:preserve_iroh_key` - Keep the iroh key from snapshot (default: false)

  ## Examples

      {:ok, vm} = Mjolnir.VM.spawn(%{base_image: "ubuntu-24.04", memory_mb: 1024})
      {:ok, vm} = Mjolnir.VM.spawn(%{snapshot: "my-snapshot", preserve_iroh_key: true})
  """
  @spec spawn(spawn_opts()) :: {:ok, t()} | {:error, term()}
  def spawn(opts \\ %{}) do
    vm_id = UUID.uuid4()

    case DynamicSupervisor.start_child(
           Mjolnir.VMSupervisor,
           {__MODULE__, Map.put(opts, :id, vm_id)}
         ) do
      {:ok, pid} ->
        # Wait for boot to complete
        case GenServer.call(pid, :await_boot, 30_000) do
          {:ok, vm} -> {:ok, vm}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Execute a command in the VM and return its output.

  Uses serial console for command execution.
  """
  @spec exec(vm_id(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def exec(vm_id, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(via_tuple(vm_id), {:exec, command}, timeout)
  end

  @doc """
  Get the current status of a VM.
  """
  @spec status(vm_id()) :: :booting | :running | :stopped | {:error, :not_found}
  def status(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, :status)
        catch
          :exit, _ -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Get the full VM state including configuration and metadata.
  """
  @spec get(vm_id()) :: {:ok, t()} | {:error, :not_found}
  def get(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        try do
          {:ok, GenServer.call(pid, :get_state)}
        catch
          :exit, _ -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Stop a VM gracefully.
  """
  @spec stop(vm_id()) :: :ok | {:error, term()}
  def stop(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Create a named snapshot of a running VM's filesystem.

  Quiesces the VM (sync + pause), takes a consistent reflink copy,
  then resumes the VM. The VM is always resumed even if the snapshot fails.

  ## Options

  - `:compact` - Run `fallocate --dig-holes` before snapshotting to reclaim freed blocks

  ## Examples

      {:ok, metadata} = Mjolnir.VM.snapshot(vm_id, "my-node-env")
  """
  @spec snapshot(vm_id(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def snapshot(vm_id, name, opts \\ []) do
    GenServer.call(via_tuple(vm_id), {:snapshot, name, opts}, 60_000)
  end

  @doc """
  List all running VMs.
  """
  @spec list() :: [t()]
  def list do
    Registry.select(Mjolnir.VMRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {_vm_id, pid} ->
      try do
        GenServer.call(pid, :get_state, 5000)
      catch
        :exit, _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Get the serial console socket path for a VM.

  Connect to this with: screen <path>

  ## Examples

      {:ok, path} = Mjolnir.VM.console(vm.id)
      # Then in another terminal: screen /tmp/mjolnir-dev/abc123_serial.sock
  """
  @spec console(vm_id()) :: {:ok, String.t()} | {:error, term()}
  def console(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        state = GenServer.call(pid, :get_state)

        if state.serial_path do
          {:ok, state.serial_path}
        else
          {:error, :no_serial_console}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Get the compact ticket (z32 node ID) for a VM.

  Returns the z32-encoded ticket string (52 chars) that can be used
  to connect to the VM's shell: `mjolnir connect <ticket>`
  """
  @spec get_ticket(vm_id()) :: {:ok, String.t()} | {:error, :not_ready | :not_found}
  def get_ticket(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        state = GenServer.call(pid, :get_state)

        if state.ticket do
          {:ok, state.ticket}
        else
          {:error, :not_ready}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Get connection info: compact ticket + full iroh JSON addr.

  The `iroh_addr` is the full iroh EndpointAddr JSON, useful for debugging
  and for clients that want relay/IP hints for faster connection.
  """
  @spec connection_info(vm_id()) ::
          {:ok, String.t(), String.t()} | {:error, :not_ready | :not_found}
  def connection_info(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        state = GenServer.call(pid, :get_state)

        if state.ticket do
          {:ok, state.ticket, state.iroh_json}
        else
          {:error, :not_ready}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Wait for shell to be ready, with timeout.

  Actively polls the guest agent for Iroh status via vsock rather than
  relying on cached boot-time values, so this works even if Iroh took
  longer than the initial boot timeout to connect to relay.

  Returns `{:ok, ticket}` when ready, or `{:error, :timeout}`.

  ## Examples

      {:ok, vm} = Mjolnir.VM.spawn()
      {:ok, ticket} = Mjolnir.VM.await_shell(vm.id)
  """
  @spec await_shell(vm_id(), timeout()) :: {:ok, String.t()} | {:error, :timeout | :not_found}
  def await_shell(vm_id, timeout \\ 30_000) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        GenServer.call(pid, {:await_shell, timeout}, timeout + 5_000)

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Print instructions for interacting with the VM.

  Serial console is currently disabled. Use `exec/2` for commands,
  or wait for networking support (TAP + SSH) for interactive shells.
  """
  @spec attach(vm_id()) :: :ok | {:error, term()}
  def attach(vm_id) do
    case status(vm_id) do
      :running ->
        IO.puts("""

        VM #{String.slice(vm_id, 0..7)}... is running.

        Interactive serial console is not currently enabled.
        Use VM.exec/2 to run commands:

          Mjolnir.VM.exec("#{vm_id}", "uname -a")
          Mjolnir.VM.exec("#{vm_id}", "ps aux")
          Mjolnir.VM.exec("#{vm_id}", "cat /etc/os-release")

        For interactive SSH access, networking support is needed (TODO).

        """)

        :ok

      other ->
        {:error, other}
    end
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts.id))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts.id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    # Resolve SSH public key: spawn opts > app config > nil
    ssh_key = opts[:ssh_public_key] || Application.get_env(:mjolnir, :default_ssh_public_key)

    state = %__MODULE__{
      id: opts.id,
      state: :booting,
      config: build_config(opts),
      ssh_public_key: ssh_key
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    case do_boot(state) do
      {:ok, new_state} ->
        {:noreply, %{new_state | state: :running, boot_time: System.monotonic_time(:millisecond)}}

      {:error, reason} ->
        Logger.error("VM #{state.id} failed to boot: #{inspect(reason)}")
        {:stop, reason, %{state | state: :failed}}
    end
  end

  @impl true
  def handle_call(:await_boot, _from, %{state: :running} = state) do
    {:reply, {:ok, state}, state}
  end

  def handle_call(:await_boot, from, %{state: :booting} = state) do
    # Store the caller to reply later when boot completes
    {:noreply, Map.put(state, :boot_waiter, from)}
  end

  def handle_call(:status, _from, state) do
    {:reply, state.state, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:exec, command}, _from, state) do
    result = execute_command(state, command)
    {:reply, result, state}
  end

  def handle_call({:snapshot, name, opts}, _from, state) do
    result = do_snapshot(state, name, opts)
    {:reply, result, state}
  end

  def handle_call({:await_shell, timeout}, _from, state) do
    # If we already have a ticket cached, return it immediately
    if state.ticket do
      {:reply, {:ok, state.ticket}, state}
    else
      # Poll the guest agent for live Iroh status via vsock
      case await_iroh_ready(state.vsock_path, timeout) do
        %{ticket: ticket} = info ->
          z32 = Mjolnir.Ticket.from_hex(info[:node_id])

          updated = %{
            state
            | iroh_node_id: info[:node_id],
              iroh_json: ticket,
              ticket: z32,
              shell_ready: true
          }

          {:reply, {:ok, z32}, updated}

        nil ->
          {:reply, {:error, :timeout}, state}
      end
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{firecracker_pid: pid} = state) do
    Logger.warning("Firecracker process exited: #{inspect(reason)}")
    {:stop, {:firecracker_exit, reason}, %{state | state: :stopped}}
  end

  def handle_info({port, {:data, data}}, %{firecracker_port: port} = state) do
    Logger.debug("Firecracker output: #{data}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{firecracker_port: port} = state) do
    Logger.info("Firecracker exited with status: #{status}")
    {:stop, {:firecracker_exit, status}, %{state | state: :stopped}}
  end

  def handle_info(msg, state) do
    Logger.debug("VM #{state.id} received: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("VM #{state.id} terminating: #{inspect(reason)}")
    cleanup(state)
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp via_tuple(vm_id) do
    {:via, Registry, {Mjolnir.VMRegistry, vm_id}}
  end

  defp build_config(opts) do
    %Config{
      vm_id: opts.id,
      kernel_path: Application.get_env(:mjolnir, :kernel_path),
      # Set during boot
      rootfs_path: "",
      base_image: opts[:base_image] || Application.get_env(:mjolnir, :default_base_image),
      vcpu_count: opts[:vcpus] || Application.get_env(:mjolnir, :default_vcpus),
      mem_size_mib: opts[:memory_mb] || Application.get_env(:mjolnir, :default_memory_mb),
      snapshot: opts[:snapshot],
      rootfs_size_mb: opts[:rootfs_size_mb],
      preserve_iroh_key: opts[:preserve_iroh_key] || false
    }
  end

  defp do_boot(state) do
    socket_dir = Application.get_env(:mjolnir, :socket_dir)
    base_image = state.config.base_image

    socket_path = Path.join(socket_dir, "#{state.id}.sock")
    vsock_path = Path.join(socket_dir, "#{state.id}_vsock.sock")
    serial_path = Path.join(socket_dir, "#{state.id}_serial.sock")

    # Remove stale sockets if they exist (ignore if missing)
    _ = File.rm(socket_path)
    _ = File.rm(vsock_path)
    _ = File.rm(serial_path)

    with :ok <- File.mkdir_p(socket_dir),
         {:ok, rootfs_path} <- clone_rootfs(state.id, base_image, state.config),
         {:ok, net_config} <- Mjolnir.Network.create_tap(state.id),
         {:ok, fc_port} <- start_firecracker(state.id, socket_path, serial_path),
         :ok <- wait_for_socket(socket_path),
         config <- %{state.config | rootfs_path: rootfs_path, network_interface: net_config},
         :ok <- configure_vm(socket_path, vsock_path, config),
         :ok <- Client.start_instance(socket_path),
         :ok <- wait_for_boot(vsock_path),
         :ok <- configure_guest_network(vsock_path, net_config.guest_ip) do
      # Inject SSH public key if provided
      if state.ssh_public_key do
        case configure_ssh(vsock_path, state.ssh_public_key) do
          :ok -> Logger.info("SSH key injected for VM #{state.id}")
          {:error, reason} -> Logger.warning("SSH key injection failed: #{inspect(reason)}")
        end
      end

      # Inject VM identity (vm_id + API URL for in-VM snapshot trigger)
      api_port = Application.get_env(:mjolnir, :api_port, 4000)
      host_ip = Application.get_env(:mjolnir, :host_api_ip, "10.200.0.1")
      api_url = "http://#{host_ip}:#{api_port}"

      case configure_identity(vsock_path, state.id, api_url) do
        :ok -> Logger.info("VM identity injected for VM #{state.id}")
        {:error, reason} -> Logger.warning("VM identity injection failed: #{inspect(reason)}")
      end

      # Try to get iroh shell info (short timeout, VM works without it)
      # Keep this short - old agents won't send iroh_ready
      iroh_info = await_iroh_ready(vsock_path, 5_000)

      {:ok,
       %{
         state
         | socket_path: socket_path,
           vsock_path: vsock_path,
           serial_path: serial_path,
           rootfs_path: rootfs_path,
           net_config: net_config,
           firecracker_port: fc_port,
           iroh_node_id: iroh_info[:node_id],
           iroh_json: iroh_info[:ticket],
           ticket: Mjolnir.Ticket.from_hex(iroh_info[:node_id]),
           shell_ready: iroh_info != nil
       }}
    end
  rescue
    e ->
      {:error, {:boot_exception, e}}
  end

  defp clone_rootfs(vm_id, base_image, config) do
    # Clone from snapshot or base image
    result =
      if config.snapshot do
        BTRFS.clone_from_snapshot(config.snapshot, vm_id)
      else
        BTRFS.clone(base_image, vm_id)
      end

    with {:ok, rootfs_path} <- result do
      # Delete iroh key from snapshot clones to ensure unique network identity
      # (unless preserve_iroh_key is set)
      if config.snapshot && !config.preserve_iroh_key do
        case BTRFS.delete_iroh_key(rootfs_path) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("Failed to delete iroh key: #{inspect(reason)}")
        end
      end

      # Optionally resize the rootfs
      if config.rootfs_size_mb do
        case BTRFS.resize_rootfs(rootfs_path, config.rootfs_size_mb) do
          :ok -> {:ok, rootfs_path}
          error -> error
        end
      else
        {:ok, rootfs_path}
      end
    end
  end

  defp start_firecracker(vm_id, socket_path, serial_path) do
    firecracker_bin = Application.get_env(:mjolnir, :firecracker_bin)
    wrapper_script = Application.get_env(:mjolnir, :console_wrapper_script)

    # Use wrapper script that exposes serial console on a Unix socket
    {executable, args} =
      if wrapper_script && File.exists?(wrapper_script) do
        {wrapper_script, [serial_path, socket_path, vm_id, firecracker_bin]}
      else
        # Direct Firecracker (no serial console socket)
        {firecracker_bin, ["--api-sock", socket_path, "--id", vm_id, "--level", "Warning"]}
      end

    port =
      Port.open(
        {:spawn_executable, executable},
        [:binary, :exit_status, :stderr_to_stdout, args: args]
      )

    {:ok, port}
  end

  defp wait_for_socket(socket_path, timeout \\ 5000) do
    wait_for_socket(socket_path, timeout, System.monotonic_time(:millisecond))
  end

  defp wait_for_socket(socket_path, timeout, start_time) do
    if File.exists?(socket_path) do
      :ok
    else
      elapsed = System.monotonic_time(:millisecond) - start_time

      if elapsed > timeout do
        {:error, :socket_timeout}
      else
        Process.sleep(50)
        wait_for_socket(socket_path, timeout, start_time)
      end
    end
  end

  defp configure_vm(socket_path, vsock_path, config) do
    with :ok <- Client.put_boot_source(socket_path, Config.boot_source(config)),
         :ok <- put_drives(socket_path, config),
         :ok <- Client.put_machine_config(socket_path, Config.machine_config(config)),
         :ok <- put_network_interface(socket_path, config),
         :ok <- Client.put_vsock(socket_path, Config.vsock(config, vsock_path)) do
      :ok
    end
  end

  defp put_network_interface(socket_path, config) do
    case Config.network_interface(config) do
      nil ->
        :ok

      net_config ->
        Client.put_network_interface(socket_path, "eth0", net_config)
    end
  end

  defp put_drives(socket_path, config) do
    Enum.reduce_while(Config.drives(config), :ok, fn drive, :ok ->
      case Client.put_drive(socket_path, drive["drive_id"], drive) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp wait_for_boot(vsock_path, timeout \\ 30_000) do
    # Wait for guest agent to respond to ping
    start_time = System.monotonic_time(:millisecond)
    wait_for_agent(vsock_path, timeout, start_time)
  end

  defp wait_for_agent(vsock_path, timeout, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed > timeout do
      {:error, :boot_timeout}
    else
      case try_ping_agent(vsock_path) do
        :ok ->
          Logger.debug("Guest agent responded after #{elapsed}ms")
          :ok

        {:error, _reason} ->
          Process.sleep(500)
          wait_for_agent(vsock_path, timeout, start_time)
      end
    end
  end

  defp await_iroh_ready(vsock_path, timeout) do
    # Poll the guest agent for Iroh status
    start_time = System.monotonic_time(:millisecond)
    do_await_iroh_ready(vsock_path, timeout, start_time)
  end

  defp do_await_iroh_ready(vsock_path, timeout, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed > timeout do
      Logger.warning("Timeout waiting for iroh_ready, shell access unavailable")
      nil
    else
      case query_iroh_status(vsock_path) do
        {:ok, %{ready: true} = info} ->
          Logger.info("VM shell ready: node_id=#{info.node_id}")
          info

        {:ok, %{ready: false}} ->
          # Not ready yet, poll again
          Process.sleep(500)
          do_await_iroh_ready(vsock_path, timeout, start_time)

        {:error, _reason} ->
          # Connection failed, retry
          Process.sleep(500)
          do_await_iroh_ready(vsock_path, timeout, start_time)
      end
    end
  end

  defp query_iroh_status(vsock_path) do
    opts = [:binary, active: false, packet: :raw]

    with {:ok, sock} <- :gen_tcp.connect({:local, vsock_path}, 0, opts, 5000),
         :ok <- :gen_tcp.send(sock, "CONNECT 5000\n"),
         {:ok, response} <- :gen_tcp.recv(sock, 0, 2000),
         true <- String.starts_with?(response, "OK") do
      # Send get_iroh_status request
      request = Mjolnir.Vsock.Protocol.get_iroh_status_request()
      message = Mjolnir.Vsock.Protocol.encode(request)
      :ok = :gen_tcp.send(sock, message)

      # Read response
      case :gen_tcp.recv(sock, 4, 5000) do
        {:ok, <<length::big-32>>} ->
          case :gen_tcp.recv(sock, length, 5000) do
            {:ok, body} ->
              :gen_tcp.close(sock)
              parse_iroh_status_response(body)

            {:error, reason} ->
              :gen_tcp.close(sock)
              {:error, {:recv_body_failed, reason}}
          end

        {:error, reason} ->
          :gen_tcp.close(sock)
          {:error, {:recv_length_failed, reason}}
      end
    else
      false -> {:error, :vsock_connect_rejected}
      {:error, reason} -> {:error, {:vsock_connect_failed, reason}}
    end
  end

  defp parse_iroh_status_response(body) do
    case Jason.decode(body) do
      {:ok, %{"type" => "iroh_status", "ready" => true, "node_id" => node_id, "ticket" => ticket}} ->
        {:ok, %{ready: true, node_id: node_id, ticket: ticket}}

      {:ok, %{"type" => "iroh_status", "ready" => false}} ->
        {:ok, %{ready: false}}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, reason} ->
        {:error, {:json_decode_failed, reason}}
    end
  end

  defp configure_guest_network(vsock_path, guest_ip) do
    # Send configure_network command to guest agent
    opts = [:binary, active: false, packet: :raw]

    with {:ok, sock} <- :gen_tcp.connect({:local, vsock_path}, 0, opts, 5000),
         :ok <- :gen_tcp.send(sock, "CONNECT 5000\n"),
         {:ok, connect_response} <- :gen_tcp.recv(sock, 0, 2000),
         true <- String.starts_with?(connect_response, "OK") do
      # Send the configure_network message
      request = Mjolnir.Vsock.Protocol.configure_network_request(guest_ip)
      message = Mjolnir.Vsock.Protocol.encode(request)

      :ok = :gen_tcp.send(sock, message)

      # Wait for response (4 byte length prefix + body)
      case :gen_tcp.recv(sock, 4, 10_000) do
        {:ok, <<length::big-32>>} ->
          case :gen_tcp.recv(sock, length, 5000) do
            {:ok, body} ->
              :gen_tcp.close(sock)

              case Jason.decode(body) do
                {:ok, %{"exit_code" => 0}} ->
                  Logger.info("Guest network configured: #{guest_ip}")
                  :ok

                {:ok, %{"exit_code" => code, "stderr" => stderr}} ->
                  Logger.error("Guest network config failed (exit #{code}): #{stderr}")
                  {:error, {:network_config_failed, code, stderr}}

                {:error, _} = err ->
                  err
              end

            {:error, reason} ->
              :gen_tcp.close(sock)
              {:error, {:recv_body_failed, reason}}
          end

        {:error, reason} ->
          :gen_tcp.close(sock)
          {:error, {:recv_length_failed, reason}}
      end
    else
      false ->
        {:error, :vsock_connect_rejected}

      {:error, reason} ->
        {:error, {:vsock_connect_failed, reason}}
    end
  end

  defp configure_ssh(vsock_path, ssh_public_key) do
    opts = [:binary, active: false, packet: :raw]

    with {:ok, sock} <- :gen_tcp.connect({:local, vsock_path}, 0, opts, 5000),
         :ok <- :gen_tcp.send(sock, "CONNECT 5000\n"),
         {:ok, connect_response} <- :gen_tcp.recv(sock, 0, 2000),
         true <- String.starts_with?(connect_response, "OK") do
      request = Mjolnir.Vsock.Protocol.configure_ssh_request(ssh_public_key)
      message = Mjolnir.Vsock.Protocol.encode(request)

      :ok = :gen_tcp.send(sock, message)

      case :gen_tcp.recv(sock, 4, 10_000) do
        {:ok, <<length::big-32>>} ->
          case :gen_tcp.recv(sock, length, 5000) do
            {:ok, body} ->
              :gen_tcp.close(sock)

              case Jason.decode(body) do
                {:ok, %{"exit_code" => 0}} ->
                  :ok

                {:ok, %{"exit_code" => code, "stderr" => stderr}} ->
                  {:error, {:ssh_config_failed, code, stderr}}

                {:error, _} = err ->
                  err
              end

            {:error, reason} ->
              :gen_tcp.close(sock)
              {:error, {:recv_body_failed, reason}}
          end

        {:error, reason} ->
          :gen_tcp.close(sock)
          {:error, {:recv_length_failed, reason}}
      end
    else
      false ->
        {:error, :vsock_connect_rejected}

      {:error, reason} ->
        {:error, {:vsock_connect_failed, reason}}
    end
  end

  defp configure_identity(vsock_path, vm_id, api_url) do
    opts = [:binary, active: false, packet: :raw]

    with {:ok, sock} <- :gen_tcp.connect({:local, vsock_path}, 0, opts, 5000),
         :ok <- :gen_tcp.send(sock, "CONNECT 5000\n"),
         {:ok, connect_response} <- :gen_tcp.recv(sock, 0, 2000),
         true <- String.starts_with?(connect_response, "OK") do
      request = Mjolnir.Vsock.Protocol.configure_identity_request(vm_id, api_url)
      message = Mjolnir.Vsock.Protocol.encode(request)

      :ok = :gen_tcp.send(sock, message)

      case :gen_tcp.recv(sock, 4, 10_000) do
        {:ok, <<length::big-32>>} ->
          case :gen_tcp.recv(sock, length, 5000) do
            {:ok, body} ->
              :gen_tcp.close(sock)

              case Jason.decode(body) do
                {:ok, %{"exit_code" => 0}} ->
                  :ok

                {:ok, %{"exit_code" => code, "stderr" => stderr}} ->
                  {:error, {:identity_config_failed, code, stderr}}

                {:error, _} = err ->
                  err
              end

            {:error, reason} ->
              :gen_tcp.close(sock)
              {:error, {:recv_body_failed, reason}}
          end

        {:error, reason} ->
          :gen_tcp.close(sock)
          {:error, {:recv_length_failed, reason}}
      end
    else
      false ->
        {:error, :vsock_connect_rejected}

      {:error, reason} ->
        {:error, {:vsock_connect_failed, reason}}
    end
  end

  defp try_ping_agent(vsock_path) do
    # Try to connect and send a ping
    opts = [:binary, active: false, packet: :raw]

    with {:ok, sock} <- :gen_tcp.connect({:local, vsock_path}, 0, opts, 2000),
         :ok <- :gen_tcp.send(sock, "CONNECT 5000\n"),
         {:ok, response} <- :gen_tcp.recv(sock, 0, 2000) do
      :gen_tcp.close(sock)

      if String.starts_with?(response, "OK") do
        :ok
      else
        {:error, {:bad_response, response}}
      end
    else
      error ->
        # Clean up socket if it was opened
        {:error, error}
    end
  end

  defp execute_command(state, command) do
    case Mjolnir.Vsock.Connection.start_link(%{
           vm_id: state.id,
           socket_path: state.vsock_path
         }) do
      {:ok, conn} ->
        result = Mjolnir.Vsock.Connection.exec(conn, command)
        GenServer.stop(conn, :normal)
        result

      {:error, reason} ->
        {:error, {:vsock_connect_failed, reason}}
    end
  end

  defp do_snapshot(state, name, opts) do
    # Step 1: Flush guest caches
    case execute_command(state, "sync") do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("Guest sync failed: #{inspect(reason)}")
    end

    # Step 2: Pause VM to stop writes
    case Client.pause_instance(state.socket_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to pause VM for snapshot: #{inspect(reason)}")
        {:error, {:pause_failed, reason}}
    end
    |> case do
      :ok ->
        try do
          # Step 3: Host-side fsync
          case File.open(state.rootfs_path, [:read]) do
            {:ok, fd} ->
              :file.sync(fd)
              File.close(fd)

            {:error, reason} ->
              Logger.warning("Host fsync failed: #{inspect(reason)}")
          end

          # Step 4: Optional compaction
          if opts[:compact] do
            BTRFS.compact_rootfs(state.rootfs_path)
          end

          # Step 5: Create the snapshot (reflink copy + metadata)
          BTRFS.create_snapshot(state.id, name, source_vm_id: state.id)
        after
          # Step 6: Always resume
          case Client.resume_instance(state.socket_path) do
            :ok ->
              Logger.debug("VM #{state.id} resumed after snapshot")

            {:error, reason} ->
              Logger.error("Failed to resume VM #{state.id} after snapshot: #{inspect(reason)}")
          end
        end

      error ->
        error
    end
  end

  defp cleanup(state) do
    # Kill Firecracker if still running
    if state.firecracker_port do
      # Get the OS PID before closing the port
      case Port.info(state.firecracker_port, :os_pid) do
        {:os_pid, os_pid} ->
          Port.close(state.firecracker_port)
          System.cmd("kill", ["-9", to_string(os_pid)])

        nil ->
          # Port already closed / process already exited
          :ok
      end
    end

    # Remove TAP interface and route
    if state.net_config do
      Logger.debug("Cleaning up TAP #{state.net_config.tap_name}")
      Mjolnir.Network.delete_tap(state.net_config.tap_name, state.net_config.guest_ip)
    end

    # Remove sockets
    if state.socket_path, do: File.rm(state.socket_path)
    if state.vsock_path, do: File.rm(state.vsock_path)
    if state.serial_path, do: File.rm(state.serial_path)

    # Remove PTY link created by console wrapper
    File.rm("/tmp/mjolnir-pty-#{state.id}")

    # Delete rootfs file and VM directory
    if state.rootfs_path do
      File.rm(state.rootfs_path)
      # Also remove the parent VM directory
      state.rootfs_path |> Path.dirname() |> File.rm_rf()
    end

    :ok
  rescue
    _ -> :ok
  end
end
