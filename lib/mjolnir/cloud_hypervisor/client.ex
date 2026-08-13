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

  # Ordinary control-plane calls answer in milliseconds; 30s is already a
  # generous "the socket is wedged" verdict.
  @default_timeout_seconds 30

  # vm.snapshot writes the full guest RAM uncompressed, and vm.restore reads it
  # back and renegotiates every vhost-user backend. Both scale with guest size,
  # so they get their own ceiling — long enough for a multi-GiB guest on slow
  # storage, still finite.
  @snapshot_timeout_seconds 600

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

  @doc """
  Capture a memory snapshot of a **paused** VM into `dest_dir`.

  CH rejects `vm.snapshot` unless the VM is already paused — the caller owns
  the pause/resume window, because that window must also contain the BTRFS
  subvolume snapshot for the two halves to be a single atomic artifact
  (`Mjolnir.MemorySnapshot`).

  Writes `config.json`, `state.json` and `memory-ranges` into `dest_dir`.
  `memory-ranges` is *uncompressed and exactly `mem_size`* — a 2 GiB VM writes
  2 GiB every time, which is why this call gets a much longer timeout than the
  rest of the API and why callers must think about retention.

  `dest_dir` must already exist; CH does not create it.
  """
  @spec snapshot_vm(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def snapshot_vm(socket_path, dest_dir, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_seconds, @snapshot_timeout_seconds)
    put(socket_path, "/api/v1/vm.snapshot", %{"destination_url" => "file://#{dest_dir}"}, timeout)
  end

  @doc """
  Restore a VM from a memory snapshot directory.

  Must be issued against a **fresh** cloud-hypervisor process started with
  `--api-socket` and *no* `--vm-config`: CH cannot restore into a VM that has
  already been created or booted. The vhost-user backends the snapshot names
  (virtiofsd, on the exact socket path recorded in `config.json`) must already
  be listening, because restore reconnects to them rather than respawning them.

  The VM comes back **paused**; call `resume_vm/1` to run it.

  ## Options

    - `:prefault` — populate guest memory eagerly (default `false`). Leaving it
      false lets CH fault pages in lazily, so restore latency does not scale
      with guest size.
  """
  @spec restore_vm(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def restore_vm(socket_path, source_dir, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_seconds, @snapshot_timeout_seconds)

    body = %{
      "source_url" => "file://#{source_dir}",
      "prefault" => Keyword.get(opts, :prefault, false)
    }

    put(socket_path, "/api/v1/vm.restore", body, timeout)
  end

  # Private HTTP helpers

  defp put(socket_path, path, body, timeout \\ @default_timeout_seconds) do
    request(:put, socket_path, path, body, timeout)
  end

  defp get(socket_path, path) do
    request(:get, socket_path, path, nil, @default_timeout_seconds)
  end

  defp request(method, socket_path, path, body, timeout) do
    case method do
      :get ->
        curl_request("GET", socket_path, path, nil, timeout)

      :put ->
        json_body = if body, do: Jason.encode!(body), else: nil
        curl_request("PUT", socket_path, path, json_body, timeout)
    end
  end

  # Use curl for Unix socket requests — Req/Finch has an issue with CH's responses
  defp curl_request(method, socket_path, path, body, timeout) do
    url = "http://localhost#{path}"

    args = [
      "-s",
      "-o",
      "/dev/null",
      "-w",
      "%{http_code}",
      # Bound every call. Before snapshot/restore existed nothing here could
      # block indefinitely, but a wedged vhost-user handshake hangs vm.restore
      # forever (this is exactly how CH v50 failed — the vmm thread parked in
      # unix_stream_data_wait and the HTTP call never returned). An unbounded
      # curl in that state takes the calling GenServer with it.
      "--max-time",
      to_string(timeout),
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
              "--max-time",
              to_string(timeout),
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

      # curl's exit 28 is "operation timed out". Distinguishing it matters:
      # a timed-out vm.restore leaves a half-restored VMM that must be killed,
      # whereas a generic curl failure usually means the socket was never there.
      {_output, 28} ->
        Logger.error("Cloud Hypervisor API call timed out after #{timeout}s: #{method} #{path}")
        {:error, {:timeout, path, timeout}}

      {output, code} ->
        Logger.error("curl failed (exit #{code}): #{output}")
        {:error, {:curl_failed, code, output}}
    end
  end
end
