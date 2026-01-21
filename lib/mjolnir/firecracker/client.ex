defmodule Mjolnir.Firecracker.Client do
  @moduledoc """
  HTTP client for Firecracker's Unix socket API.

  Firecracker exposes a REST API over a Unix domain socket.
  We configure the VM by making PUT requests to various endpoints.
  """

  require Logger

  @doc """
  Configure the boot source (kernel).
  """
  def put_boot_source(socket_path, boot_source) do
    put(socket_path, "/boot-source", boot_source)
  end

  @doc """
  Configure a drive.
  """
  def put_drive(socket_path, drive_id, drive_config) do
    put(socket_path, "/drives/#{drive_id}", drive_config)
  end

  @doc """
  Configure machine resources (vCPUs, memory).
  """
  def put_machine_config(socket_path, machine_config) do
    put(socket_path, "/machine-config", machine_config)
  end

  @doc """
  Configure vsock device.
  """
  def put_vsock(socket_path, vsock_config) do
    put(socket_path, "/vsock", vsock_config)
  end

  @doc """
  Start the VM (InstanceStart action).
  """
  def start_instance(socket_path) do
    put(socket_path, "/actions", %{"action_type" => "InstanceStart"})
  end

  @doc """
  Pause the VM.
  """
  def pause_instance(socket_path) do
    patch(socket_path, "/vm", %{"state" => "Paused"})
  end

  @doc """
  Resume the VM.
  """
  def resume_instance(socket_path) do
    patch(socket_path, "/vm", %{"state" => "Resumed"})
  end

  @doc """
  Get VM info.
  """
  def get_info(socket_path) do
    get(socket_path, "/")
  end

  # Private HTTP helpers

  defp put(socket_path, path, body) do
    request(:put, socket_path, path, body)
  end

  defp patch(socket_path, path, body) do
    request(:patch, socket_path, path, body)
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

        :patch ->
          Req.patch(req, url: path, json: body)
      end

    case result do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: 204}} ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Firecracker API error: #{status} - #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("Firecracker request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
