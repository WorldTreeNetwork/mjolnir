defmodule Mjolnir.Hypervisor.Firecracker do
  @moduledoc """
  Firecracker hypervisor implementation.

  **DEPRECATED**: Firecracker does not support virtio-fs, which is required for
  Mjolnir's current storage architecture (BTRFS subvolumes shared via virtio-fs).
  Use `Mjolnir.Hypervisor.CloudHypervisor` instead. This module is retained for
  reference but is not actively maintained or tested.

  This module implements the `Mjolnir.Hypervisor` behaviour for Firecracker,
  wrapping the existing `Mjolnir.Firecracker.Client` and extracting hypervisor-specific
  logic from `Mjolnir.VM`.
  """

  @behaviour Mjolnir.Hypervisor

  require Logger

  alias Mjolnir.Firecracker.{Client, Config}

  @doc """
  Start a Firecracker VM process.

  Launches the firecracker binary via Port.open. Optionally uses a wrapper script
  to expose the serial console on a Unix socket.

  ## Config Map

  - `:vm_id` - VM identifier
  - `:socket_path` - Firecracker API socket path
  - `:serial_path` - Serial console socket path (optional)

  Reads `:firecracker_bin` and `:console_wrapper_script` from application config.
  """
  @impl true
  @spec start_vm(map()) :: {:ok, port()} | {:error, term()}
  def start_vm(config) do
    vm_id = config.vm_id
    socket_path = config.socket_path
    serial_path = config[:serial_path]
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

  @doc """
  Configure the Firecracker VM via REST API.

  Delegates to `Mjolnir.Firecracker.Client` to set boot source, drives,
  machine config, vsock, and network interface.

  ## Parameters

  - `socket_path` - Firecracker API socket path
  - `config` - Plain map with VM configuration (will be converted to Config struct)
  """
  @impl true
  @spec configure_vm(String.t(), map()) :: :ok | {:error, term()}
  def configure_vm(socket_path, config) when is_map(config) do
    # Convert plain map to Firecracker Config struct, filtering to known fields
    known_keys = Config.__struct__() |> Map.keys() |> MapSet.new()
    filtered = Map.filter(config, fn {k, _v} -> MapSet.member?(known_keys, k) end)
    config_struct = struct!(Config, filtered)
    vsock_path = vsock_path(socket_path |> Path.dirname(), config_struct.vm_id)

    with :ok <- Client.put_boot_source(socket_path, Config.boot_source(config_struct)),
         :ok <- put_drives(socket_path, config_struct),
         :ok <- Client.put_machine_config(socket_path, Config.machine_config(config_struct)),
         :ok <- put_network_interface(socket_path, config_struct),
         :ok <- Client.put_vsock(socket_path, Config.vsock(config_struct, vsock_path)) do
      :ok
    end
  end

  @doc """
  Start the Firecracker instance.

  Sends InstanceStart action to the Firecracker API, booting the VM.
  """
  @impl true
  @spec start_instance(String.t()) :: :ok | {:error, term()}
  def start_instance(socket_path) do
    Client.start_instance(socket_path)
  end

  @doc """
  Pause the Firecracker instance.

  Sets VM state to Paused, freezing execution for snapshotting.
  """
  @impl true
  @spec pause_instance(String.t()) :: :ok | {:error, term()}
  def pause_instance(socket_path) do
    Client.pause_instance(socket_path)
  end

  @doc """
  Resume a paused Firecracker instance.

  Sets VM state to Resumed, unfreezing execution.
  """
  @impl true
  @spec resume_instance(String.t()) :: :ok | {:error, term()}
  def resume_instance(socket_path) do
    Client.resume_instance(socket_path)
  end

  @doc """
  Stop the Firecracker instance.

  Currently a no-op, as cleanup is handled by killing the process.
  Firecracker doesn't support graceful shutdown via API.
  """
  @impl true
  @spec stop_instance(String.t()) :: :ok | {:error, term()}
  def stop_instance(_socket_path) do
    # Firecracker doesn't have a graceful shutdown API
    # Cleanup is done by killing the process
    :ok
  end

  @doc """
  Clean up all Firecracker VM resources.

  This function:
  1. Stops the persistent vsock connection
  2. Kills the Firecracker process via SIGKILL
  3. Removes TAP network interface
  4. Removes socket files (API, vsock, serial)
  5. Removes PTY link
  6. Deletes rootfs file and VM directory

  Mirrors the cleanup logic from `Mjolnir.VM.cleanup/1`.
  """
  @impl true
  @spec cleanup(map()) :: :ok
  def cleanup(state) do
    # Stop persistent vsock connection
    if state[:vsock_conn] do
      GenServer.stop(state.vsock_conn, :normal)
    end

    # Kill Firecracker if still running
    if state[:hypervisor_port] do
      # Get the OS PID before closing the port
      case Port.info(state.hypervisor_port, :os_pid) do
        {:os_pid, os_pid} ->
          Port.close(state.hypervisor_port)
          System.cmd("kill", ["-9", to_string(os_pid)])

        nil ->
          # Port already closed / process already exited
          :ok
      end
    end

    # Remove TAP interface and route
    if state[:net_config] do
      try do
        Logger.debug("Cleaning up TAP #{state.net_config.tap_name}")
        Mjolnir.Network.delete_tap(state.net_config.tap_name, state.net_config.guest_ip)
      rescue
        e -> Logger.warning("TAP cleanup failed for #{state[:id]}: #{inspect(e)}")
      end
    end

    # Remove sockets
    if state[:socket_path], do: File.rm(state.socket_path)
    if state[:vsock_path], do: File.rm(state.vsock_path)
    if state[:serial_path], do: File.rm(state.serial_path)

    # Remove PTY link created by console wrapper
    if state[:id] do
      File.rm("/tmp/mjolnir-pty-#{state.id}")
    end

    # Delete rootfs file and VM directory
    if state[:rootfs_path] do
      vm_dir = Path.dirname(state.rootfs_path)

      if Regex.match?(~r/^[0-9a-f]{8}-/, Path.basename(vm_dir)) do
        File.rm_rf(vm_dir)
      else
        File.rm(state.rootfs_path)
      end
    end

    :ok
  rescue
    e ->
      Logger.warning("Cleanup error for VM #{state[:id]}: #{inspect(e)}")
      :ok
  end

  @doc """
  Get the vsock socket path for a Firecracker VM.

  Firecracker creates vsock Unix sockets following the pattern:
  `<socket_dir>/<vm_id>_vsock.sock`
  """
  @impl true
  @spec vsock_path(String.t(), String.t()) :: String.t()
  def vsock_path(socket_dir, vm_id) do
    Path.join(socket_dir, "#{vm_id}_vsock.sock")
  end

  @doc """
  Get the Firecracker process name for cleanup.

  Returns "firecracker" to identify orphaned processes during startup cleanup.
  """
  @impl true
  @spec process_name() :: String.t()
  def process_name do
    "firecracker"
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

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
end
