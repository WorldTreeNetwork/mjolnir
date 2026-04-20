defmodule Mjolnir.VirtioFS do
  @moduledoc """
  Manages virtiofsd process lifecycle for virtio-fs shared directories.

  virtiofsd exposes host directories to Cloud Hypervisor VMs via the
  virtio-fs protocol. Each VM can have one or more shared directories,
  each backed by a dedicated virtiofsd process.

  ## Process lifecycle

  1. Start virtiofsd before VM boot (creates vhost-user socket)
  2. VM boots and mounts shared directory via virtio-fs
  3. On VM stop, virtiofsd is cleaned up after VM process

  ## Crash handling

  If virtiofsd crashes, the VM continues running but the shared directory
  becomes unavailable. A warning is logged but the VM is not terminated.

  ## Example

      socket_dir = Application.get_env(:mjolnir, :socket_dir)
      socket_path = Mjolnir.VirtioFS.socket_path(socket_dir, vm_id)
      shared_dir = "/tmp/shared"

      {:ok, port} = Mjolnir.VirtioFS.start(shared_dir, socket_path, thread_pool_size: 8)

      # ... VM runs with shared directory mounted ...

      Mjolnir.VirtioFS.stop(port)
      Mjolnir.VirtioFS.cleanup(socket_path)
  """

  require Logger

  @default_thread_pool_size 4

  @doc """
  Start a virtiofsd daemon process.

  Spawns virtiofsd as a Port (for crash isolation) with the given shared
  directory and vhost-user socket path.

  ## Arguments

  - `shared_dir`: Host directory to expose to the VM
  - `socket_path`: Path for vhost-user socket (created by virtiofsd)
  - `opts`: Optional configuration
    - `:thread_pool_size` - Number of worker threads (default: #{@default_thread_pool_size})
    - `:virtiofsd_bin` - Path to virtiofsd binary (default: "virtiofsd")

  ## Returns

  - `{:ok, port}` on success
  - `{:error, reason}` if virtiofsd fails to start

  ## Example

      {:ok, port} = Mjolnir.VirtioFS.start(
        "/tmp/shared",
        "/tmp/sockets/vm123_virtiofs.sock",
        thread_pool_size: 8
      )
  """
  @spec start(String.t(), String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def start(shared_dir, socket_path, opts \\ []) do
    unless File.dir?(shared_dir) do
      {:error, {:shared_dir_not_found, shared_dir}}
    else
      do_start(shared_dir, socket_path, opts)
    end
  end

  defp do_start(shared_dir, socket_path, opts) do
    # Ensure socket directory exists
    socket_dir = Path.dirname(socket_path)
    File.mkdir_p(socket_dir)

    # Remove stale socket if it exists
    File.rm(socket_path)

    virtiofsd_bin =
      Keyword.get(
        opts,
        :virtiofsd_bin,
        Application.get_env(:mjolnir, :virtiofsd_bin, "virtiofsd")
      )

    thread_pool_size = Keyword.get(opts, :thread_pool_size, @default_thread_pool_size)

    args = [
      "--socket-path=#{socket_path}",
      "--shared-dir=#{shared_dir}",
      "--cache=auto",
      "--sandbox=none",
      "--thread-pool-size=#{thread_pool_size}"
    ]

    Logger.info("Starting virtiofsd: #{shared_dir} -> #{socket_path}")

    try do
      port =
        Port.open(
          {:spawn_executable, virtiofsd_bin},
          [:binary, :exit_status, :stderr_to_stdout, args: args]
        )

      # Wait for socket to be created (virtiofsd is ready). The port-aware
      # wait drains stderr + detects early exit so we don't silently time
      # out when virtiofsd crashes on startup.
      case wait_for_socket_or_exit(socket_path, 5000, port) do
        :ok ->
          Logger.debug("virtiofsd socket ready: #{socket_path}")
          {:ok, port}

        {:error, reason} ->
          Logger.error("virtiofsd failed to create socket: #{inspect(reason)}")
          safe_port_close(port)
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("Failed to start virtiofsd: #{inspect(e)}")
        {:error, {:virtiofsd_start_failed, e}}
    end
  end

  defp safe_port_close(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end

  @doc """
  Stop a virtiofsd process gracefully.

  Closes the Port, which sends SIGTERM to the virtiofsd process.
  If the process doesn't exit cleanly, a SIGKILL is sent.

  ## Example

      Mjolnir.VirtioFS.stop(port)
  """
  @spec stop(port()) :: :ok
  def stop(port) when is_port(port) do
    Logger.debug("Stopping virtiofsd port #{inspect(port)}")

    # Get OS PID before closing port
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        Port.close(port)

        # Give it a moment to exit cleanly
        Process.sleep(100)

        # Force kill if still running
        case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
          {_, 0} ->
            Logger.debug("Sending SIGKILL to virtiofsd PID #{os_pid}")
            System.cmd("kill", ["-9", to_string(os_pid)])

          _ ->
            # Process already exited
            :ok
        end

      nil ->
        # Port already closed
        :ok
    end

    :ok
  end

  @doc """
  Generate the socket path for a VM's virtiofsd instance.

  Follows the convention: `{socket_dir}/{vm_id}_virtiofs.sock`

  ## Example

      socket_path = Mjolnir.VirtioFS.socket_path("/tmp/sockets", "abc123")
      # => "/tmp/sockets/abc123_virtiofs.sock"
  """
  @spec socket_path(String.t(), String.t()) :: String.t()
  def socket_path(socket_dir, vm_id) do
    Path.join(socket_dir, "#{vm_id}_virtiofs.sock")
  end

  @doc """
  Check if a virtiofsd port is still alive.

  ## Example

      if Mjolnir.VirtioFS.alive?(port) do
        IO.puts("virtiofsd is running")
      end
  """
  @spec alive?(port()) :: boolean()
  def alive?(port) when is_port(port) do
    Port.info(port) != nil
  end

  @doc """
  Clean up virtiofsd socket file.

  Removes the vhost-user socket file if it exists. Safe to call even
  if the socket doesn't exist.

  Called during VM teardown after the virtiofsd process has been stopped.

  ## Example

      Mjolnir.VirtioFS.cleanup("/tmp/sockets/vm123_virtiofs.sock")
  """
  @spec cleanup(String.t()) :: :ok
  def cleanup(socket_path) do
    case File.rm(socket_path) do
      :ok ->
        Logger.debug("Removed virtiofsd socket: #{socket_path}")
        :ok

      {:error, :enoent} ->
        # Socket doesn't exist, that's fine
        :ok

      {:error, reason} ->
        Logger.warning("Failed to remove virtiofsd socket #{socket_path}: #{inspect(reason)}")
        :ok
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Port-aware wait: drains virtiofsd's stderr into the log, detects early
  # exit (socket never created → {:virtiofsd_exited, status}), so failures
  # are diagnosable instead of a silent :socket_timeout.
  defp wait_for_socket_or_exit(socket_path, timeout, port) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_port(socket_path, deadline, port, [])
  end

  defp do_wait_port(socket_path, deadline, port, stderr_acc) do
    if File.exists?(socket_path) do
      :ok
    else
      remaining = max(0, deadline - System.monotonic_time(:millisecond))

      receive do
        {^port, {:data, data}} ->
          do_wait_port(socket_path, deadline, port, [data | stderr_acc])

        {^port, {:exit_status, status}} ->
          stderr = stderr_acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()

          if stderr != "" do
            Logger.error("virtiofsd stderr: #{stderr}")
          end

          {:error, {:virtiofsd_exited, status, stderr}}
      after
        min(50, remaining) ->
          if System.monotonic_time(:millisecond) >= deadline do
            stderr = stderr_acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()

            if stderr != "" do
              Logger.warning("virtiofsd stderr (at timeout): #{stderr}")
            end

            {:error, :socket_timeout}
          else
            do_wait_port(socket_path, deadline, port, stderr_acc)
          end
      end
    end
  end
end
