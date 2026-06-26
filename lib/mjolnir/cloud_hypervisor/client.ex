defmodule Mjolnir.CloudHypervisor.Client do
  @moduledoc """
  HTTP client for Cloud Hypervisor's Unix socket API.

  Cloud Hypervisor (v50.0) exposes a REST API over a Unix domain socket.
  A single `vm.create` call sends the full VM configuration, then `vm.boot`
  starts the instance.

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
    Logger.debug("vm.create payload: #{Jason.encode!(vm_config, pretty: true)}")
    put(socket_path, "/api/v1/vm.create", vm_config)
  end

  @doc """
  Boot the VM (start instance).

  CH v50 rejects requests with a body on this endpoint.
  """
  def boot_vm(socket_path) do
    put(socket_path, "/api/v1/vm.boot", nil)
  end

  @doc """
  Pause the VM.
  """
  def pause_vm(socket_path) do
    put(socket_path, "/api/v1/vm.pause", nil)
  end

  @doc """
  Resume the VM.
  """
  def resume_vm(socket_path) do
    put(socket_path, "/api/v1/vm.resume", nil)
  end

  @doc """
  Reboot the VM in place.

  Issues `PUT /api/v1/vm.reboot`, which the hypervisor implements as a hard
  reset of the guest (vCPUs reset, kernel re-entered) without tearing down the
  CH process, sockets, TAP, or virtiofs backend. This is the recovery path for
  a guest that is wedged but whose CH instance still reports `Running` (e.g. a
  guest left frozen by a pause/resume during snapshot).
  """
  def reboot_vm(socket_path) do
    put(socket_path, "/api/v1/vm.reboot", nil)
  end

  @doc """
  Shutdown the VM gracefully.
  """
  def shutdown_vm(socket_path) do
    put(socket_path, "/api/v1/vm.shutdown", nil)
  end

  @doc """
  Delete VM resources.
  """
  def delete_vm(socket_path) do
    put(socket_path, "/api/v1/vm.delete", nil)
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
    case method do
      :get ->
        curl_request("GET", socket_path, path, nil)

      :put ->
        json_body = if body, do: Jason.encode!(body), else: nil
        curl_request("PUT", socket_path, path, json_body)
    end
  end

  # Use curl for Unix socket requests — Req/Finch has an issue with CH's responses
  defp curl_request(method, socket_path, path, body) do
    url = "http://localhost#{path}"

    args = [
      "-s",
      "-o",
      "/dev/null",
      "-w",
      "%{http_code}",
      "--unix-socket",
      socket_path,
      "-X",
      method,
      url
    ]

    args =
      if body do
        args ++ ["-H", "Content-Type: application/json", "-d", body]
      else
        args
      end

    case System.cmd("curl", args, stderr_to_stdout: true) do
      {status_str, 0} ->
        status = String.trim(status_str) |> String.to_integer()

        if status in 200..299 do
          :ok
        else
          # Re-run to capture body for error reporting
          body_args =
            [
              "-s",
              "--unix-socket",
              socket_path,
              "-X",
              method,
              url
            ] ++ if(body, do: ["-H", "Content-Type: application/json", "-d", body], else: [])

          {error_body, _} = System.cmd("curl", body_args, stderr_to_stdout: true)
          Logger.error("Cloud Hypervisor API error: #{status} - #{String.trim(error_body)}")
          {:error, {:api_error, status, String.trim(error_body)}}
        end

      {output, code} ->
        Logger.error("curl failed (exit #{code}): #{output}")
        {:error, {:curl_failed, code, output}}
    end
  end
end
