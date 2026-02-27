defmodule Mjolnir.CloudHypervisor.Client do
  @moduledoc """
  HTTP client for Cloud Hypervisor's Unix socket API.

  Cloud Hypervisor (v50.0) exposes a REST API over a Unix domain socket.
  Unlike Firecracker's multi-step configuration, Cloud Hypervisor uses a
  single `vm.create` call with the full VM configuration, then `vm.boot`
  to start the instance.

  ## API Reference

  - `PUT /api/v1/vm.create` - Create VM with full config
  - `PUT /api/v1/vm.boot` - Boot the VM
  - `PUT /api/v1/vm.pause` - Pause the VM
  - `PUT /api/v1/vm.resume` - Resume the VM
  - `PUT /api/v1/vm.shutdown` - Graceful shutdown
  - `PUT /api/v1/vm.delete` - Delete VM resources
  - `GET /api/v1/vm.info` - Get VM info

  Pinned to Cloud Hypervisor v50.0.
  """

  require Logger

  @doc """
  Create a VM with the given configuration.

  The config should contain the full VM specification including kernel,
  memory, CPUs, disks, network, and vsock.
  """
  def create_vm(socket_path, vm_config) do
    Logger.info("vm.create payload: #{Jason.encode!(vm_config, pretty: true)}")
    put(socket_path, "/api/v1/vm.create", vm_config)
  end

  @doc """
  Boot the VM (start instance).
  """
  def boot_vm(socket_path) do
    put(socket_path, "/api/v1/vm.boot", %{})
  end

  @doc """
  Pause the VM.
  """
  def pause_vm(socket_path) do
    put(socket_path, "/api/v1/vm.pause", %{})
  end

  @doc """
  Resume the VM.
  """
  def resume_vm(socket_path) do
    put(socket_path, "/api/v1/vm.resume", %{})
  end

  @doc """
  Shutdown the VM gracefully.
  """
  def shutdown_vm(socket_path) do
    put(socket_path, "/api/v1/vm.shutdown", %{})
  end

  @doc """
  Delete VM resources.
  """
  def delete_vm(socket_path) do
    put(socket_path, "/api/v1/vm.delete", %{})
  end

  @doc """
  Get VM info.
  """
  def get_info(socket_path) do
    get(socket_path, "/api/v1/vm.info")
  end

  @doc """
  Resize VM resources (CPU, memory, or both).
  """
  def resize(socket_path, resize_config) do
    put(socket_path, "/api/v1/vm.resize", resize_config)
  end

  # Private HTTP helpers

  defp put(socket_path, path, body) do
    request(:put, socket_path, path, body)
  end

  defp get(socket_path, path) do
    request(:get, socket_path, path, nil)
  end

  defp request(method, socket_path, path, body) do
    # Req supports Unix sockets via the unix_socket option
    opts = [
      unix_socket: socket_path,
      base_url: "http://localhost",
      receive_timeout: 30_000
    ]

    req = Req.new(opts)

    result =
      case method do
        :get ->
          Req.get(req, url: path)

        :put ->
          Req.put(req, url: path, json: body)
      end

    case result do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Cloud Hypervisor API error: #{status} - #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("Cloud Hypervisor request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
