defmodule Mjolnir.VM do
  @moduledoc """
  MicroVM lifecycle management.

  Spawns microVMs via pluggable hypervisor backends (Cloud Hypervisor default)
  with BTRFS-backed filesystems and provides command execution via vsock.
  """

  use GenServer, restart: :transient
  require Logger

  alias Mjolnir.BTRFS

  defstruct [
    :id,
    :config,
    :hypervisor,
    :hypervisor_pid,
    :hypervisor_port,
    :socket_path,
    :vsock_path,
    :vsock_conn,
    :serial_path,
    :rootfs_path,
    :virtiofsd_port,
    :net_config,
    :state,
    :boot_time,
    # Iroh shell support
    :iroh_node_id,
    :iroh_json,
    :ticket,
    :pty_ready,
    # Ownership (multi-tenancy)
    :owner_id,
    # SSH key injection
    :ssh_public_key,
    # Iroh networking toggle
    enable_iroh: false,
    # Secrets mode: :none (default) | :persistent (LUKS encrypted volume)
    secrets_mode: :none,
    # Inter-VM message queue (buffered during boot)
    message_queue: [],
    # Resume mode: true when booting an existing VM from StateStore (skips
    # rootfs clone + guest agent re-injection). Set by Mjolnir.Reconcile.
    resume_mode: false
  ]

  @config_key_allowlist ~w(vcpus memory_mb enable_iroh ssh_public_key owner_id snapshot preserve_iroh_key secrets_mode)

  @type t :: %__MODULE__{}
  @type vm_id :: String.t()
  @type spawn_opts :: %{
          optional(:base_image) => String.t(),
          optional(:vcpus) => pos_integer(),
          optional(:memory_mb) => pos_integer(),
          optional(:ssh_public_key) => String.t(),
          optional(:snapshot) => String.t(),
          optional(:preserve_iroh_key) => boolean(),
          optional(:enable_iroh) => boolean(),
          optional(:owner_id) => String.t() | nil
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Spawn a new MicroVM.

  ## Options

  - `:base_image` - Base image name (default: "arch"; other option: "ubuntu-24.04")
  - `:vcpus` - Number of vCPUs (default: 2)
  - `:memory_mb` - Memory in MiB (default: 512)
  - `:snapshot` - Snapshot name to spawn from (instead of base image)
  - `:preserve_iroh_key` - Keep the iroh key from snapshot (default: false)

  ## Examples

      {:ok, vm} = Mjolnir.VM.spawn(%{base_image: "arch", memory_mb: 1024})
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
    timeout = Keyword.get(opts, :timeout, :infinity)
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
  Wait for PTY to be ready, with timeout.

  Actively polls the guest agent for Iroh status via vsock rather than
  relying on cached boot-time values, so this works even if Iroh took
  longer than the initial boot timeout to connect to relay.

  Returns `{:ok, ticket}` when ready, or `{:error, :timeout}`.

  ## Examples

      {:ok, vm} = Mjolnir.VM.spawn(%{enable_iroh: true})
      {:ok, ticket} = Mjolnir.VM.await_pty(vm.id)
  """
  @spec await_pty(vm_id(), timeout()) :: {:ok, String.t()} | {:error, :timeout | :not_found}
  def await_pty(vm_id, timeout \\ 30_000) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        GenServer.call(pid, {:await_pty, timeout}, timeout + 5_000)

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

  @doc """
  Authorize an Iroh peer for secret injection into a VM.
  The peer's NodeId will be sent to the guest agent, which will allow
  SECRET_INJECT_ALPN connections from that peer.
  """
  @spec authorize_inject_peer(vm_id(), String.t()) :: :ok | {:error, term()}
  def authorize_inject_peer(vm_id, peer_node_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] -> GenServer.call(pid, {:authorize_inject_peer, peer_node_id})
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Deliver a message from one VM to another.

  Routes through the VMRegistry for running VMs, or through the
  DormantRegistry for checkpointed VMs (triggering a restore).
  """
  @spec deliver_message(vm_id(), String.t(), term()) :: :ok | {:error, term()}
  def deliver_message(target_vm_id, from_vm_id, payload) do
    case Registry.lookup(Mjolnir.VMRegistry, target_vm_id) do
      [{pid, _}] ->
        GenServer.call(pid, {:deliver_message, from_vm_id, payload})

      [] ->
        # Check if the VM is dormant
        case Mjolnir.DormantRegistry.lookup(target_vm_id) do
          {:ok, _entry} ->
            case Mjolnir.DormantRegistry.queue_message(target_vm_id, from_vm_id, payload) do
              :ok ->
                restore_dormant_vm(target_vm_id)

              {:error, :restoring} ->
                # VM is being restored — retry delivery via VMRegistry
                # (it may be booting, in which case the message gets queued in the VM GenServer)
                retry_deliver_message(target_vm_id, from_vm_id, payload)

              {:error, :not_found} ->
                {:error, :not_found}
            end

          :not_found ->
            {:error, :not_found}
        end
    end
  end

  @doc """
  Handle a VM signaling "done" — snapshot and go dormant.

  Called by the vsock connection handler when the guest sends signal_done.
  """
  @spec handle_done(vm_id()) :: :ok | {:error, term()}
  def handle_done(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        GenServer.call(pid, :handle_done, 60_000)

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Open or ensure a terminal session in the VM"
  @spec terminal_open(vm_id(), String.t()) :: {:ok, map()} | {:error, term()}
  def terminal_open(vm_id, session_name) do
    GenServer.call(via_tuple(vm_id), {:terminal_open, session_name})
  end

  @doc "Read terminal content"
  @spec terminal_read(vm_id(), String.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def terminal_read(vm_id, session_name, scrollback_lines \\ 100) do
    GenServer.call(via_tuple(vm_id), {:terminal_read, session_name, scrollback_lines})
  end

  @doc "Send command or keys to terminal"
  @spec terminal_send(vm_id(), String.t(), String.t() | nil, list() | nil) ::
          {:ok, map()} | {:error, term()}
  def terminal_send(vm_id, session_name, command \\ nil, keys \\ nil) do
    GenServer.call(via_tuple(vm_id), {:terminal_send, session_name, command, keys})
  end

  @doc "Send command and wait for output"
  @spec terminal_send_and_read(vm_id(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def terminal_send_and_read(vm_id, session_name, command, timeout_ms \\ 30_000) do
    GenServer.call(
      via_tuple(vm_id),
      {:terminal_send_and_read, session_name, command, timeout_ms},
      timeout_ms + 10_000
    )
  end

  @doc "List terminal sessions"
  @spec terminal_list(vm_id()) :: {:ok, map()} | {:error, term()}
  def terminal_list(vm_id) do
    GenServer.call(via_tuple(vm_id), :terminal_list)
  end

  @doc "Close a terminal session"
  @spec terminal_close(vm_id(), String.t()) :: {:ok, map()} | {:error, term()}
  def terminal_close(vm_id, session_name) do
    GenServer.call(via_tuple(vm_id), {:terminal_close, session_name})
  end

  @doc """
  Spawn a VM with a pre-assigned ID (used for restoring dormant VMs).

  Like `spawn/1` but uses the given `:id` from opts instead of generating a new UUID.
  """
  @spec spawn_with_id(spawn_opts()) :: {:ok, t()} | {:error, term()}
  def spawn_with_id(opts) do
    vm_id = opts[:id] || raise ArgumentError, ":id is required for spawn_with_id"

    case DynamicSupervisor.start_child(
           Mjolnir.VMSupervisor,
           {__MODULE__, Map.put(opts, :id, vm_id)}
         ) do
      {:ok, pid} ->
        case GenServer.call(pid, :await_boot, 30_000) do
          {:ok, vm} -> {:ok, vm}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resume a VM from a persisted StateStore record. Used by `Mjolnir.Reconcile`
  at boot. Skips rootfs clone (uses existing `@vms/<uuid>` subvolume) and
  skips guest-agent injection. Network/identity/iroh are re-pushed
  idempotently to recover from any guest drift.
  """
  @spec resume(Mjolnir.StateStore.Record.t()) :: {:ok, t()} | {:error, term()}
  def resume(%Mjolnir.StateStore.Record{uuid: uuid, spawn_config: cfg}) do
    opts = %{
      id: uuid,
      resume: true,
      base_image: Map.get(cfg, "base_image"),
      vcpus: Map.get(cfg, "vcpus"),
      memory_mb: Map.get(cfg, "memory_mb"),
      enable_iroh: Map.get(cfg, "enable_iroh"),
      owner_id: Map.get(cfg, "owner_id"),
      ssh_public_key: Map.get(cfg, "ssh_public_key"),
      secrets_mode:
        case Map.get(cfg, "secrets_mode") do
          "persistent" -> :persistent
          _ -> :none
        end
    }

    case DynamicSupervisor.start_child(
           Mjolnir.VMSupervisor,
           {__MODULE__, opts}
         ) do
      {:ok, pid} ->
        case GenServer.call(pid, :await_boot, 60_000) do
          {:ok, vm} -> {:ok, vm}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
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

    # Resolve enable_iroh: spawn opts > app config > true
    enable_iroh =
      case opts[:enable_iroh] do
        nil -> Application.get_env(:mjolnir, :enable_iroh, true)
        val -> val
      end

    # Resolve hypervisor: spawn opts > app config > default
    hypervisor = opts[:hypervisor] || Mjolnir.Hypervisor.impl()

    state = %__MODULE__{
      id: opts.id,
      state: :booting,
      config: build_config(opts),
      hypervisor: hypervisor,
      ssh_public_key: ssh_key,
      enable_iroh: enable_iroh,
      owner_id: opts[:owner_id],
      resume_mode: opts[:resume] || false
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    case do_boot(state) do
      {:ok, new_state} ->
        # Drain any messages queued during boot
        for {from_vm_id, payload} <- new_state.message_queue do
          Mjolnir.Vsock.Connection.deliver_message(new_state.vsock_conn, from_vm_id, payload)
        end

        running_state = %{
          new_state
          | state: :running,
            boot_time: System.system_time(:millisecond),
            message_queue: []
        }

        persist_running_state(running_state)

        {:noreply, running_state}

      {:error, reason} ->
        Logger.error("VM #{state.id} failed to boot: #{inspect(reason)}")
        # Return :normal so the :transient DynamicSupervisor does NOT restart
        # (transient processes only restart on abnormal termination)
        {:stop, :normal, %{state | state: :failed}}
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

  def handle_call({:deliver_message, from_vm_id, payload}, _from, %{state: :running} = state) do
    Mjolnir.Vsock.Connection.deliver_message(state.vsock_conn, from_vm_id, payload)
    {:reply, :ok, state}
  end

  def handle_call({:deliver_message, from_vm_id, payload}, _from, %{state: :booting} = state) do
    {:reply, :ok, %{state | message_queue: state.message_queue ++ [{from_vm_id, payload}]}}
  end

  def handle_call({:deliver_message, _from_vm_id, _payload}, _from, state) do
    {:reply, {:error, {:not_available, state.state}}, state}
  end

  # VMs with persistent secrets cannot go dormant — nobody can provide the
  # passphrase when auto-restoring on incoming message.
  def handle_call(:handle_done, _from, %{secrets_mode: :persistent} = state) do
    Logger.warning(
      "VM #{state.id} has secrets_mode=persistent, refusing dormancy. " <>
        "Stop explicitly with VM.stop/1 or snapshot manually with VM.snapshot/2."
    )

    {:reply, {:error, :secrets_prevent_dormancy}, state}
  end

  def handle_call(:handle_done, _from, state) do
    snapshot_name = "dormant-#{state.id}-#{System.os_time(:second)}"

    case do_snapshot(state, snapshot_name, []) do
      {:ok, _metadata} ->
        original_config = restore_config(state)
        Mjolnir.DormantRegistry.register(state.id, snapshot_name, original_config, state.owner_id)
        # DormantRegistry now owns this VM's persisted state; remove the
        # running-intent record so Mjolnir.Reconcile doesn't try to resume it.
        _ = Mjolnir.StateStore.delete(state.id)
        Mjolnir.EventBus.publish(state.id, :vm_dormant, %{snapshot: snapshot_name})
        {:stop, :normal, :ok, state}

      {:error, reason} ->
        Logger.error("Failed to snapshot VM #{state.id} for done: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:exec, command}, _from, state) do
    result = execute_command(state, command)
    {:reply, result, state}
  end

  def handle_call({:authorize_inject_peer, peer_node_id}, _from, state) do
    if state.vsock_conn do
      request = Mjolnir.Vsock.Protocol.configure_secrets_auth_request([peer_node_id])

      case Mjolnir.Vsock.Connection.send_request(state.vsock_conn, request) do
        {:ok, _stdout} -> {:reply, :ok, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :no_vsock_connection}, state}
    end
  end

  def handle_call({:terminal_open, session_name}, _from, state) do
    result =
      if state.vsock_conn,
        do: Mjolnir.Vsock.Connection.terminal_open(state.vsock_conn, session_name),
        else: {:error, :no_vsock_connection}

    {:reply, result, state}
  end

  def handle_call({:terminal_read, session_name, scrollback_lines}, _from, state) do
    result =
      if state.vsock_conn,
        do:
          Mjolnir.Vsock.Connection.terminal_read(
            state.vsock_conn,
            session_name,
            scrollback_lines
          ),
        else: {:error, :no_vsock_connection}

    {:reply, result, state}
  end

  def handle_call({:terminal_send, session_name, command, keys}, _from, state) do
    result =
      if state.vsock_conn,
        do: Mjolnir.Vsock.Connection.terminal_send(state.vsock_conn, session_name, command, keys),
        else: {:error, :no_vsock_connection}

    {:reply, result, state}
  end

  # IMPORTANT: terminal_send_and_read is handled asynchronously to avoid blocking
  # the VM GenServer for up to 30+ seconds. Other terminal/exec calls can proceed
  # concurrently while this long-running operation is in flight.
  def handle_call({:terminal_send_and_read, session_name, command, timeout_ms}, from, state) do
    if state.vsock_conn do
      conn = state.vsock_conn

      Task.Supervisor.start_child(Mjolnir.TaskSupervisor, fn ->
        try do
          result =
            Mjolnir.Vsock.Connection.terminal_send_and_read(
              conn,
              session_name,
              command,
              timeout_ms
            )

          GenServer.reply(from, result)
        catch
          kind, reason ->
            GenServer.reply(from, {:error, {kind, reason}})
        end
      end)

      {:noreply, state}
    else
      {:reply, {:error, :no_vsock_connection}, state}
    end
  end

  def handle_call(:terminal_list, _from, state) do
    result =
      if state.vsock_conn,
        do: Mjolnir.Vsock.Connection.terminal_list(state.vsock_conn),
        else: {:error, :no_vsock_connection}

    {:reply, result, state}
  end

  def handle_call({:terminal_close, session_name}, _from, state) do
    result =
      if state.vsock_conn,
        do: Mjolnir.Vsock.Connection.terminal_close(state.vsock_conn, session_name),
        else: {:error, :no_vsock_connection}

    {:reply, result, state}
  end

  def handle_call({:snapshot, name, opts}, _from, state) do
    result = do_snapshot(state, name, opts)
    {:reply, result, state}
  end

  def handle_call({:await_pty, timeout}, _from, state) do
    # If iroh is disabled, PTY is available over vsock immediately
    unless state.enable_iroh do
      {:reply, {:ok, state.id}, %{state | pty_ready: true}}
    else
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
                pty_ready: true
            }

            {:reply, {:ok, z32}, updated}

          nil ->
            {:reply, {:error, :timeout}, state}
        end
      end
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{hypervisor_pid: pid} = state) do
    Logger.warning("Hypervisor process exited: #{inspect(reason)}")
    {:stop, {:hypervisor_exit, reason}, %{state | state: :stopped}}
  end

  def handle_info({port, {:data, data}}, %{hypervisor_port: port} = state) do
    Logger.debug("Hypervisor output: #{data}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{hypervisor_port: port} = state) do
    Logger.info("Hypervisor exited with status: #{status}")
    {:stop, {:hypervisor_exit, status}, %{state | state: :stopped}}
  end

  def handle_info({port, {:data, data}}, %{virtiofsd_port: port} = state) when is_port(port) do
    Logger.debug("virtiofsd output: #{data}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{virtiofsd_port: port} = state)
      when is_port(port) do
    Logger.warning("virtiofsd exited with status #{status} for VM #{state.id}")
    {:noreply, %{state | virtiofsd_port: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("VM #{state.id} received: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("VM #{state.id} terminating: #{inspect(reason)} (state=#{state.state})")

    # Durability: preserve rootfs and StateStore record unless we're sure the
    # VM should be gone forever. "Sure" = the VM was successfully running AND
    # this exit is :normal (user-initiated VM.stop or handle_done dormant
    # transition). Every other path — supervisor :shutdown, hypervisor crash,
    # boot failure mid-resume — preserves so Mjolnir.Reconcile can retry.
    preserve = preserve_rootfs?(reason, state)

    if state.hypervisor_port || state.net_config || state.rootfs_path do
      cleanup(state, preserve_rootfs: preserve)
    end

    unless preserve do
      _ = Mjolnir.StateStore.delete(state.id)
    end

    :ok
  end

  defp preserve_rootfs?(:normal, %{state: :running}), do: false
  defp preserve_rootfs?(_reason, _state), do: true

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp via_tuple(vm_id) do
    {:via, Registry, {Mjolnir.VMRegistry, vm_id}}
  end

  defp build_config(opts) do
    %{
      vm_id: opts.id,
      kernel_path: Application.get_env(:mjolnir, :kernel_path),
      # Set during boot
      rootfs_path: "",
      base_image: opts[:base_image] || Application.get_env(:mjolnir, :default_base_image),
      vcpu_count: opts[:vcpus] || Application.get_env(:mjolnir, :default_vcpus),
      mem_size_mib: opts[:memory_mb] || Application.get_env(:mjolnir, :default_memory_mb),
      vsock_cid: generate_vsock_cid(opts.id),
      snapshot: opts[:snapshot],
      preserve_iroh_key: opts[:preserve_iroh_key] || false,
      resume: opts[:resume] || false
    }
  end

  # Generate a unique vsock CID from the VM's UUID.
  # CIDs 0-2 are reserved by the kernel, so we map into the range [3, 0xFFFFFFFF).
  # Uses the first 4 bytes of the UUID's MD5 hash to produce a deterministic,
  # collision-resistant 32-bit CID.
  defp generate_vsock_cid(vm_id) do
    <<cid_raw::unsigned-32, _rest::binary>> = :crypto.hash(:md5, vm_id)
    # Ensure CID >= 3 (0-2 are reserved) and avoid 0xFFFFFFFF (VMADDR_CID_ANY)
    rem(cid_raw, 0xFFFFFFFF - 3) + 3
  end

  defp do_boot(state) do
    socket_dir = Application.get_env(:mjolnir, :socket_dir)
    base_image = state.config.base_image
    hypervisor = state.hypervisor

    socket_path = Path.join(socket_dir, "#{state.id}.sock")
    vsock_path = hypervisor.vsock_path(socket_dir, state.id)
    serial_path = Path.join(socket_dir, "#{state.id}_serial.sock")

    # Remove stale sockets if they exist (ignore if missing)
    _ = File.rm(socket_path)
    _ = File.rm(vsock_path)
    _ = File.rm(serial_path)

    # Use Process dictionary to track partially-created resources for cleanup
    Process.put(:boot_partial, %{})

    result =
      with :ok <- File.mkdir_p(socket_dir),
           {:ok, rootfs_path} <- clone_rootfs(state.id, base_image, state.config),
           _ = track_rootfs_for_cleanup(state, rootfs_path),
           _ = maybe_inject_guest_agent(state, rootfs_path),
           virtiofsd_socket = Mjolnir.VirtioFS.socket_path(socket_dir, state.id),
           {:ok, virtiofsd_port} <- Mjolnir.VirtioFS.start(rootfs_path, virtiofsd_socket),
           _ = boot_partial_put(:virtiofsd_port, virtiofsd_port),
           {:ok, net_config} <- Mjolnir.Network.create_tap(state.id),
           _ = boot_partial_put(:net_config, net_config),
           {:ok, hv_port} <- start_hypervisor(hypervisor, state.id, socket_path, serial_path),
           _ = boot_partial_put(:hv_port, hv_port),
           :ok <- wait_for_socket(socket_path),
           config <-
             Map.merge(state.config, %{
               rootfs_path: rootfs_path,
               network_interface: net_config,
               virtiofsd_socket: virtiofsd_socket
             }),
           :ok <- configure_vm(hypervisor, socket_path, config),
           :ok <- hypervisor.start_instance(socket_path),
           :ok <- wait_for_boot(vsock_path, state),
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

        # Tell guest agent whether to start Iroh
        case configure_iroh(vsock_path, state.enable_iroh) do
          :ok ->
            Logger.info(
              "Iroh #{if state.enable_iroh, do: "enabled", else: "disabled"} for VM #{state.id}"
            )

          {:error, reason} ->
            Logger.warning("configure_iroh failed: #{inspect(reason)}")
        end

        # Only wait for Iroh if enabled
        iroh_info =
          if state.enable_iroh do
            await_iroh_ready(vsock_path, 5_000)
          else
            nil
          end

        # Start persistent vsock connection for command execution
        {:ok, vsock_conn} =
          Mjolnir.Vsock.Connection.start_link(%{
            vm_id: state.id,
            socket_path: vsock_path
          })

        Process.delete(:boot_partial)

        {:ok,
         %{
           state
           | socket_path: socket_path,
             vsock_path: vsock_path,
             vsock_conn: vsock_conn,
             serial_path: serial_path,
             rootfs_path: rootfs_path,
             net_config: net_config,
             hypervisor_port: hv_port,
             virtiofsd_port: virtiofsd_port,
             iroh_node_id: iroh_info[:node_id],
             iroh_json: iroh_info[:ticket],
             ticket: Mjolnir.Ticket.from_hex(iroh_info[:node_id]),
             pty_ready: iroh_info != nil
         }}
      else
        error ->
          cleanup_partial_boot(state.hypervisor, socket_path, vsock_path, serial_path)
          error
      end

    result
  rescue
    e ->
      cleanup_partial_boot(state.hypervisor, nil, nil, nil)
      {:error, {:boot_exception, e}}
  end

  defp boot_partial_put(key, value) do
    partial = Process.get(:boot_partial, %{})
    Process.put(:boot_partial, Map.put(partial, key, value))
  end

  defp cleanup_partial_boot(_hypervisor, socket_path, vsock_path, serial_path) do
    partial = Process.get(:boot_partial, %{})
    Process.delete(:boot_partial)

    Logger.debug("Cleaning up partially-created boot resources: #{inspect(Map.keys(partial))}")

    # Kill hypervisor port if started
    if partial[:hv_port] do
      try do
        case Port.info(partial.hv_port, :os_pid) do
          {:os_pid, os_pid} ->
            Port.close(partial.hv_port)
            System.cmd("kill", ["-9", to_string(os_pid)])

          nil ->
            :ok
        end
      rescue
        _ -> :ok
      end
    end

    # Stop virtiofsd if started
    if partial[:virtiofsd_port] do
      try do
        Mjolnir.VirtioFS.stop(partial.virtiofsd_port)
      rescue
        _ -> :ok
      end
    end

    # Delete TAP if created
    if partial[:net_config] do
      try do
        Mjolnir.Network.delete_tap(partial.net_config.tap_name, partial.net_config.guest_ip)
      rescue
        _ -> :ok
      end
    end

    # Remove rootfs if cloned
    if partial[:rootfs_path] do
      try do
        Mjolnir.BTRFS.delete_subvolume(partial.rootfs_path)
      rescue
        # May fail on macOS (no btrfs) -- that's OK for tests
        _ -> File.rm_rf(partial.rootfs_path)
      end
    end

    # Remove sockets
    if socket_path, do: File.rm(socket_path)
    if vsock_path, do: File.rm(vsock_path)
    if serial_path, do: File.rm(serial_path)

    :ok
  rescue
    _ -> :ok
  end

  defp inject_guest_agent(rootfs_dir) do
    agent_bin = Application.get_env(:mjolnir, :guest_agent_bin)

    if agent_bin && File.exists?(agent_bin) do
      dest = Path.join(rootfs_dir, "usr/local/bin/mjolnir-agent")
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(agent_bin, dest)
      File.chmod!(dest, 0o755)
      Logger.info("Injected current guest agent into rootfs")
    end

    :ok
  rescue
    e ->
      Logger.warning("Guest agent injection failed: #{inspect(e)}")
      :ok
  end

  defp clone_rootfs(vm_id, base_image, config) do
    cond do
      config[:resume] ->
        # Resume mode: use the existing @vms/<uuid> subvolume left over from a
        # previous mjolnir run. If it's missing, the VM can't be rehydrated —
        # the caller (Mjolnir.Reconcile) should have checked first, so a missing
        # rootfs here is a bug or a race with manual cleanup.
        btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
        subdir = Application.get_env(:mjolnir, :vm_storage_subdir, "@vms")
        rootfs_path = Path.join([btrfs_root, subdir, vm_id])

        if File.exists?(rootfs_path) do
          {:ok, rootfs_path}
        else
          {:error, {:resume_rootfs_missing, rootfs_path}}
        end

      config.snapshot ->
        with {:ok, rootfs_path} <- BTRFS.clone_from_snapshot(config.snapshot, vm_id) do
          unless config.preserve_iroh_key do
            case BTRFS.delete_iroh_key(rootfs_path) do
              :ok -> :ok
              {:error, reason} -> Logger.warning("Failed to delete iroh key: #{inspect(reason)}")
            end
          end

          {:ok, rootfs_path}
        end

      true ->
        BTRFS.clone(base_image, vm_id)
    end
  end

  defp maybe_inject_guest_agent(%__MODULE__{resume_mode: true}, _rootfs_path), do: :ok
  defp maybe_inject_guest_agent(_state, rootfs_path), do: inject_guest_agent(rootfs_path)

  # In resume mode, the subvolume was created by a previous mjolnir run and
  # must NOT be torn down by cleanup_partial_boot on a retryable boot failure.
  # Only track rootfs in boot_partial for fresh spawns.
  defp track_rootfs_for_cleanup(%__MODULE__{resume_mode: true}, _rootfs_path), do: :ok
  defp track_rootfs_for_cleanup(_state, rootfs_path), do: boot_partial_put(:rootfs_path, rootfs_path)

  defp start_hypervisor(hypervisor, vm_id, socket_path, serial_path) do
    config = %{
      vm_id: vm_id,
      socket_path: socket_path,
      serial_path: serial_path
    }

    hypervisor.start_vm(config)
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

  defp configure_vm(hypervisor, socket_path, config) do
    hypervisor.configure_vm(socket_path, config)
  end

  defp wait_for_boot(vsock_path, _state, timeout \\ 30_000) do
    start_time = System.monotonic_time(:millisecond)
    # Two-phase wait works for both legacy and initramfs modes:
    # - Legacy: first ping returns :full → done immediately
    # - Initramfs: first ping returns :boot → wait for :full after switch_root
    wait_for_agent(vsock_path, timeout, start_time)
  end

  defp wait_for_agent(vsock_path, timeout, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed > timeout do
      {:error, :boot_timeout}
    else
      case try_ping_agent(vsock_path) do
        {:ok, :full} ->
          Logger.debug("Guest agent (full) responded after #{elapsed}ms")
          :ok

        {:ok, :boot} ->
          Logger.debug("Boot agent responded after #{elapsed}ms, waiting for full agent")
          Process.sleep(500)
          wait_for_agent(vsock_path, timeout, start_time)

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
          Logger.info("VM PTY ready: node_id=#{info.node_id}")
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
    request = Mjolnir.Vsock.Protocol.get_iroh_status_request()

    case vsock_request(vsock_path, request, 5000) do
      {:ok, response} -> parse_iroh_status_response(response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_iroh_status_response(%{
         "type" => "iroh_status",
         "ready" => true,
         "node_id" => node_id,
         "ticket" => ticket
       }) do
    {:ok, %{ready: true, node_id: node_id, ticket: ticket}}
  end

  defp parse_iroh_status_response(%{"type" => "iroh_status", "ready" => false}) do
    {:ok, %{ready: false}}
  end

  defp parse_iroh_status_response(other) do
    {:error, {:unexpected_response, other}}
  end

  defp configure_guest_network(vsock_path, guest_ip) do
    request = Mjolnir.Vsock.Protocol.configure_network_request(guest_ip)

    case vsock_request(vsock_path, request) do
      {:ok, %{"exit_code" => 0}} ->
        Logger.info("Guest network configured: #{guest_ip}")
        :ok

      {:ok, %{"exit_code" => code, "stderr" => stderr}} ->
        Logger.error("Guest network config failed (exit #{code}): #{stderr}")
        {:error, {:network_config_failed, code, stderr}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp configure_ssh(vsock_path, ssh_public_key) do
    request = Mjolnir.Vsock.Protocol.configure_ssh_request(ssh_public_key)

    case vsock_request(vsock_path, request) do
      {:ok, %{"exit_code" => 0}} ->
        :ok

      {:ok, %{"exit_code" => code, "stderr" => stderr}} ->
        {:error, {:ssh_config_failed, code, stderr}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp configure_identity(vsock_path, vm_id, api_url) do
    request = Mjolnir.Vsock.Protocol.configure_identity_request(vm_id, api_url)

    case vsock_request(vsock_path, request) do
      {:ok, %{"exit_code" => 0}} ->
        :ok

      {:ok, %{"exit_code" => code, "stderr" => stderr}} ->
        {:error, {:identity_config_failed, code, stderr}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp configure_iroh(vsock_path, enabled) do
    request = Mjolnir.Vsock.Protocol.configure_iroh_request(enabled)

    case vsock_request(vsock_path, request) do
      {:ok, %{"type" => "configure_iroh_response", "ok" => true}} ->
        :ok

      {:ok, %{"type" => "configure_iroh_response", "ok" => false}} ->
        {:error, :configure_iroh_rejected}

      {:ok, other} ->
        # Old agent that doesn't understand configure_iroh — treat as ok
        Logger.debug("Unexpected configure_iroh response: #{inspect(other)}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Vsock Helpers - Synchronous request/response pattern
  # ============================================================================

  defp vsock_connect(vsock_path, timeout) do
    opts = [:binary, active: false, packet: :raw]

    with {:ok, sock} <- :gen_tcp.connect({:local, vsock_path}, 0, opts, timeout),
         :ok <- :gen_tcp.send(sock, "CONNECT 5000\n"),
         {:ok, response} <- :gen_tcp.recv(sock, 0, timeout) do
      if String.starts_with?(response, "OK") do
        {:ok, sock}
      else
        :gen_tcp.close(sock)
        {:error, {:vsock_connect_rejected, response}}
      end
    else
      {:error, reason} -> {:error, {:vsock_connect_failed, reason}}
    end
  end

  defp vsock_request(vsock_path, request_map, timeout \\ 10_000) do
    with {:ok, sock} <- vsock_connect(vsock_path, timeout) do
      message = Mjolnir.Vsock.Protocol.encode(request_map)
      :ok = :gen_tcp.send(sock, message)

      # Read response (1 byte channel + 4 byte length prefix + body)
      result =
        with {:ok, <<_channel::8, length::big-32>>} <- :gen_tcp.recv(sock, 5, timeout),
             {:ok, body} <- :gen_tcp.recv(sock, length, timeout),
             {:ok, parsed} <- Jason.decode(body) do
          {:ok, parsed}
        else
          {:error, reason} -> {:error, reason}
        end

      :gen_tcp.close(sock)
      result
    end
  end

  defp try_ping_agent(vsock_path) do
    alias Mjolnir.Vsock.Protocol
    ping_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    ping = %{"type" => "ping", "id" => ping_id}
    timeout = 2000

    with {:ok, sock} <- vsock_connect(vsock_path, timeout),
         :ok <- :gen_tcp.send(sock, Protocol.encode(ping)),
         {:ok, <<_channel::8, length::big-32>>} <- :gen_tcp.recv(sock, 5, timeout),
         {:ok, body} <- :gen_tcp.recv(sock, length, timeout),
         :ok <- :gen_tcp.close(sock),
         {:ok, %{"type" => "pong"} = pong} <- Jason.decode(body) do
      agent_type = if pong["agent"] == "boot", do: :boot, else: :full
      {:ok, agent_type}
    else
      {:ok, unexpected} ->
        {:error, {:unexpected_response, unexpected}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_command(state, command) do
    if state.vsock_conn do
      Mjolnir.Vsock.Connection.exec(state.vsock_conn, command, :infinity)
    else
      {:error, :no_vsock_connection}
    end
  end

  defp do_snapshot(state, name, opts) do
    # Step 1: Flush guest caches
    case execute_command(state, "sync") do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("Guest sync failed: #{inspect(reason)}")
    end

    # Step 2: Pause VM to stop writes
    case state.hypervisor.pause_instance(state.socket_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to pause VM for snapshot: #{inspect(reason)}")
        {:error, {:pause_failed, reason}}
    end
    |> case do
      :ok ->
        try do
          # No host-side fsync needed: guest sync is performed above, and
          # btrfs subvolume snapshot is atomic at the filesystem level.

          # Create the snapshot (subvolume snapshot + metadata)
          BTRFS.create_snapshot(state.id, name,
            source_vm_id: state.id,
            owner_id: opts[:owner_id] || state.owner_id
          )
        after
          # Step 6: Always resume
          case state.hypervisor.resume_instance(state.socket_path) do
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

  defp cleanup(state, opts) do
    preserve_rootfs = Keyword.get(opts, :preserve_rootfs, false)

    # The hypervisor's cleanup/1 only deletes the subvolume when state.rootfs_path
    # is set. Nilling it lets us keep the rest of the teardown (CH process, TAP,
    # sockets, virtiofsd) while preserving rootfs for Mjolnir.Reconcile.
    effective_state = if preserve_rootfs, do: %{state | rootfs_path: nil}, else: state

    if state.hypervisor do
      state.hypervisor.cleanup(effective_state)
    else
      Logger.warning("No hypervisor set for VM #{state.id}, skipping cleanup")
    end

    :ok
  rescue
    _ -> :ok
  end

  defp persist_running_state(state) do
    record =
      Mjolnir.StateStore.Record.new(state.id, :running,
        spawn_config: %{
          "vcpus" => state.config.vcpu_count,
          "memory_mb" => state.config.mem_size_mib,
          "base_image" => state.config.base_image,
          "enable_iroh" => state.enable_iroh,
          "owner_id" => state.owner_id,
          "ssh_public_key" => state.ssh_public_key,
          "secrets_mode" => Atom.to_string(state.secrets_mode)
        },
        identity: %{
          "iroh_node_id" => state.iroh_node_id,
          "hostname" => nil,
          "ssh_authorized_keys_hash" => nil
        },
        runtime: %{
          "ch_api_socket" => state.socket_path,
          "vsock_uds" => state.vsock_path
        },
        last_boot_at: DateTime.utc_now()
      )

    case Mjolnir.StateStore.put(record) do
      :ok ->
        :ok

      {:error, reason} ->
        # Durability failure is logged but does not fail the VM — the VM is
        # running, we just won't be able to resurrect it on mjolnir restart.
        Logger.warning(
          "Failed to persist StateStore record for VM #{state.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # ============================================================================
  # Dormant VM Helpers
  # ============================================================================

  # Retry delivering a message when the DormantRegistry is in :restoring state.
  # The VM should already be in VMRegistry (booting or running).
  defp retry_deliver_message(target_vm_id, from_vm_id, payload, retries \\ 5) do
    case Registry.lookup(Mjolnir.VMRegistry, target_vm_id) do
      [{pid, _}] ->
        GenServer.call(pid, {:deliver_message, from_vm_id, payload})

      [] when retries > 0 ->
        Process.sleep(200)
        retry_deliver_message(target_vm_id, from_vm_id, payload, retries - 1)

      [] ->
        Logger.warning(
          "Failed to deliver message to restoring VM #{target_vm_id}: not in registry"
        )

        {:error, :not_found}
    end
  end

  defp restore_config(state) do
    %{
      base_image: state.config.base_image,
      vcpus: state.config.vcpu_count,
      memory_mb: state.config.mem_size_mib,
      enable_iroh: state.enable_iroh,
      ssh_public_key: state.ssh_public_key,
      owner_id: state.owner_id,
      secrets_mode: state.secrets_mode
    }
  end

  defp normalize_config_keys(config) do
    Map.new(config, fn
      {k, v} when is_binary(k) ->
        if k in @config_key_allowlist, do: {String.to_atom(k), v}, else: {k, v}

      {k, v} ->
        {k, v}
    end)
  end

  defp restore_dormant_vm(vm_id) do
    case Mjolnir.DormantRegistry.begin_restore(vm_id) do
      :ok ->
        Task.Supervisor.start_child(Mjolnir.TaskSupervisor, fn ->
          do_restore_dormant_vm(vm_id)
        end)

        :ok

      :already_restoring ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_restore_dormant_vm(vm_id) do
    case Mjolnir.DormantRegistry.lookup(vm_id) do
      {:ok, entry} ->
        # Spawn the VM from its dormant snapshot, reusing the same VM ID
        opts =
          entry.original_config
          |> normalize_config_keys()
          |> Map.merge(%{
            id: vm_id,
            snapshot: entry.snapshot_name,
            preserve_iroh_key: false
          })

        case spawn_with_id(opts) do
          {:ok, _vm} ->
            # Atomically take pending messages and unregister in one sequence.
            # Unregister first so new deliver_message calls route via VMRegistry
            # (the VM is already registered there after spawn_with_id).
            pending = Mjolnir.DormantRegistry.take_pending_messages(vm_id)
            Mjolnir.DormantRegistry.unregister(vm_id)

            for {from_vm_id, payload} <- pending do
              # The VM is now running, deliver via registry
              case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
                [{pid, _}] ->
                  GenServer.call(pid, {:deliver_message, from_vm_id, payload})

                [] ->
                  Logger.warning(
                    "Restored VM #{vm_id} not found in registry for message delivery"
                  )
              end
            end

            Mjolnir.EventBus.publish(vm_id, :vm_restored, %{from_snapshot: entry.snapshot_name})
            Logger.info("Successfully restored dormant VM #{vm_id}")

          {:error, reason} ->
            Logger.error("Failed to restore dormant VM #{vm_id}: #{inspect(reason)}")
            Mjolnir.DormantRegistry.cancel_restore(vm_id)
        end

      :not_found ->
        Logger.warning("Dormant VM #{vm_id} not found during restore")
    end
  end
end
