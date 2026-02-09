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
    :rootfs_path,
    :state,
    :boot_time
  ]

  @type t :: %__MODULE__{}
  @type vm_id :: String.t()
  @type spawn_opts :: %{
          optional(:base_image) => String.t(),
          optional(:vcpus) => pos_integer(),
          optional(:memory_mb) => pos_integer()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Spawn a new MicroVM.

  ## Options

  - `:base_image` - Base image name (default: "debian-12")
  - `:vcpus` - Number of vCPUs (default: 2)
  - `:memory_mb` - Memory in MiB (default: 512)

  ## Examples

      {:ok, vm} = Mjolnir.VM.spawn(%{base_image: "debian-12", memory_mb: 1024})
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
      [{pid, _}] -> GenServer.call(pid, :status)
      [] -> {:error, :not_found}
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

    state = %__MODULE__{
      id: opts.id,
      state: :booting,
      config: build_config(opts)
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
      mem_size_mib: opts[:memory_mb] || Application.get_env(:mjolnir, :default_memory_mb)
    }
  end

  defp do_boot(state) do
    socket_dir = Application.get_env(:mjolnir, :socket_dir)
    base_image = state.config.base_image

    socket_path = Path.join(socket_dir, "#{state.id}.sock")
    vsock_path = Path.join(socket_dir, "#{state.id}_vsock.sock")

    # Remove stale sockets if they exist (ignore if missing)
    _ = File.rm(socket_path)
    _ = File.rm(vsock_path)

    with :ok <- File.mkdir_p(socket_dir),
         {:ok, rootfs_path} <- BTRFS.clone(base_image, state.id),
         {:ok, fc_port} <- start_firecracker(state.id, socket_path),
         :ok <- wait_for_socket(socket_path),
         :ok <- configure_vm(socket_path, vsock_path, %{state.config | rootfs_path: rootfs_path}),
         :ok <- Client.start_instance(socket_path),
         :ok <- wait_for_boot(vsock_path) do
      {:ok,
       %{
         state
         | socket_path: socket_path,
           vsock_path: vsock_path,
           rootfs_path: rootfs_path,
           firecracker_port: fc_port
       }}
    end
  rescue
    e ->
      {:error, {:boot_exception, e}}
  end

  defp start_firecracker(vm_id, socket_path) do
    firecracker_bin = Application.get_env(:mjolnir, :firecracker_bin)

    args = [
      "--api-sock",
      socket_path,
      "--id",
      vm_id,
      "--level",
      "Warning"
    ]

    port =
      Port.open(
        {:spawn_executable, firecracker_bin},
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
         :ok <- Client.put_vsock(socket_path, Config.vsock(config, vsock_path)) do
      :ok
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

    # Remove sockets
    if state.socket_path, do: File.rm(state.socket_path)
    if state.vsock_path, do: File.rm(state.vsock_path)

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
