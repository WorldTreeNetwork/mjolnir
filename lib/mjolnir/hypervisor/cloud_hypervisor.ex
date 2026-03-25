defmodule Mjolnir.Hypervisor.CloudHypervisor do
  @moduledoc """
  Cloud Hypervisor backend implementation.

  Implements the `Mjolnir.Hypervisor` behaviour for Cloud Hypervisor v50.0.

  Cloud Hypervisor is a modern, lightweight VMM built in Rust, focused on
  running cloud workloads with minimal overhead. It supports virtio-vsock
  for host-guest communication and provides a REST API over Unix sockets.

  ## Key Differences from Firecracker

  - Single `vm.create` call with full config vs. Firecracker's multi-step PUT sequence
  - Binary name: `cloud-hypervisor` vs. `firecracker`
  - Vsock socket path: `{socket_dir}/{vm_id}_vsock` (CH convention)
  - Supports virtio-fs for shared filesystem access (future use)

  Pinned to Cloud Hypervisor v50.0.
  """

  @behaviour Mjolnir.Hypervisor

  require Logger

  alias Mjolnir.CloudHypervisor.{Client, Config}

  @impl true
  def start_vm(config) do
    ch_bin = Application.get_env(:mjolnir, :cloud_hypervisor_bin, "cloud-hypervisor")
    socket_path = config.socket_path
    vm_id = config.vm_id

    args = [
      "--api-socket",
      socket_path,
      "--log-file",
      "/tmp/cloud-hypervisor-#{vm_id}.log"
    ]

    port =
      Port.open(
        {:spawn_executable, ch_bin},
        [:binary, :exit_status, :stderr_to_stdout, args: args]
      )

    {:ok, port}
  end

  @impl true
  def configure_vm(socket_path, config) do
    # Use CH-specific kernel if configured (CH needs PVH boot support)
    ch_kernel = Application.get_env(:mjolnir, :ch_kernel_path)

    config =
      if ch_kernel && File.exists?(ch_kernel),
        do: Map.put(config, :kernel_path, ch_kernel),
        else: config

    # Use initramfs if configured (two-phase boot: initramfs → virtiofs rootfs)
    # Boot args must omit root=/rootfstype= when initramfs handles mounting (TC6)
    config =
      if initramfs_path = Application.get_env(:mjolnir, :initramfs_path) do
        Map.merge(config, %{
          initramfs_path: initramfs_path,
          boot_args: "console=ttyS0 reboot=k panic=1 rw"
        })
      else
        config
      end

    # Build the full vm.create payload, filtering to known Config fields
    known_keys = Config.__struct__() |> Map.keys() |> MapSet.new()
    filtered = Map.filter(config, fn {k, _v} -> MapSet.member?(known_keys, k) end)
    ch_config = struct!(Config, filtered)
    socket_dir = Path.dirname(socket_path)
    vsock_path = vsock_path(socket_dir, ch_config.vm_id)
    payload = Config.vm_create_payload(ch_config, vsock_path)

    # Single API call to create the VM with full configuration
    case Client.create_vm(socket_path, payload) do
      :ok ->
        Logger.debug("Cloud Hypervisor VM created: #{config.vm_id}")
        :ok

      {:error, reason} ->
        Logger.error("Cloud Hypervisor vm.create failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def start_instance(socket_path) do
    Client.boot_vm(socket_path)
  end

  @impl true
  def pause_instance(socket_path) do
    Client.pause_vm(socket_path)
  end

  @impl true
  def resume_instance(socket_path) do
    Client.resume_vm(socket_path)
  end

  @impl true
  def stop_instance(socket_path) do
    with :ok <- Client.shutdown_vm(socket_path),
         :ok <- Client.delete_vm(socket_path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Cloud Hypervisor shutdown/delete failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def cleanup(state) do
    # Stop persistent vsock connection
    if state[:vsock_conn] do
      GenServer.stop(state.vsock_conn, :normal, 5000)
    end

    # Kill Cloud Hypervisor if still running
    if state[:hypervisor_port] do
      case Port.info(state.hypervisor_port, :os_pid) do
        {:os_pid, os_pid} ->
          Port.close(state.hypervisor_port)
          System.cmd("kill", ["-9", to_string(os_pid)])

        nil ->
          :ok
      end
    end

    # Stop virtiofsd if running
    if state[:virtiofsd_port] do
      Mjolnir.VirtioFS.stop(state.virtiofsd_port)
    end

    # Clean up virtiofsd socket
    if state[:id] do
      socket_dir = Application.get_env(:mjolnir, :socket_dir)
      virtiofsd_socket = Mjolnir.VirtioFS.socket_path(socket_dir, state.id)
      Mjolnir.VirtioFS.cleanup(virtiofsd_socket)
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

    # Remove socket files
    if state[:socket_path], do: File.rm(state.socket_path)
    if state[:vsock_path], do: File.rm(state.vsock_path)

    # Remove PTY link
    if state[:id] do
      File.rm("/tmp/mjolnir-pty-#{state.id}")
    end

    # Remove Cloud Hypervisor log file
    if state[:id] do
      File.rm("/tmp/cloud-hypervisor-#{state.id}.log")
    end

    # Delete rootfs subvolume
    if state[:rootfs_path] do
      try do
        Mjolnir.BTRFS.delete_subvolume(state.rootfs_path)
      rescue
        e -> Logger.warning("Rootfs subvolume cleanup failed: #{inspect(e)}")
      end
    end

    :ok
  rescue
    e ->
      Logger.warning("Cleanup error for VM #{state[:id]}: #{inspect(e)}")
      :ok
  end

  @impl true
  def vsock_path(socket_dir, vm_id) do
    # Cloud Hypervisor convention: {socket_dir}/{vm_id}_vsock
    Path.join(socket_dir, "#{vm_id}_vsock")
  end

  @impl true
  def process_name do
    "cloud-hypervisor"
  end
end
