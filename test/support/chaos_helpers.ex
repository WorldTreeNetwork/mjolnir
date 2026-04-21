defmodule Mjolnir.Chaos.Helpers do
  @moduledoc """
  Helpers for chaos tests that run against a live server (prod, by default).

  All commands go through SSH + SSH-tunneled curl — the same shape Justfile
  uses — because Mjolnir's API auth bypass only works for connections from
  127.0.0.1, and a curl from your Mac would get `401`.

  Set `MJOLNIR_HOST=root@45.76.77.97` in your environment (or `.env` picked
  up by Justfile) before running. The helper raises if it's unset so you
  never accidentally target localhost.
  """

  @api "http://localhost:4000/api"

  @doc "The configured target host, e.g. `root@45.76.77.97`."
  def host do
    System.get_env("MJOLNIR_HOST") ||
      raise "MJOLNIR_HOST not set — chaos tests require an explicit target host. " <>
              "Either export MJOLNIR_HOST or run via `just chaos`."
  end

  @doc "Run an arbitrary shell command on the target host, returning {stdout, exit_code}."
  @spec ssh(String.t(), keyword()) :: {String.t(), non_neg_integer()}
  def ssh(cmd, opts \\ []) do
    System.cmd("ssh", [host(), cmd], Keyword.merge([stderr_to_stdout: true], opts))
  end

  @doc """
  HTTP request via SSH-tunneled curl. Returns `{:ok, decoded_json}` on 2xx,
  `{:error, {:http, status, body}}` on non-2xx, `{:error, reason}` otherwise.
  """
  @spec api(String.t(), String.t(), map() | nil) ::
          {:ok, term()} | {:error, term()}
  def api(method, path, body \\ nil) do
    url = @api <> path

    base_args = [
      host(),
      curl_cmd(method, url, body)
    ]

    case System.cmd("ssh", base_args, stderr_to_stdout: true) do
      {out, 0} ->
        parse_http_response(out)

      {out, code} ->
        {:error, {:ssh_failed, code, String.trim(out)}}
    end
  end

  defp curl_cmd(method, url, nil) do
    ~s(curl -sS -w '\\nHTTP_STATUS:%{http_code}\\n' -X #{method} #{url})
  end

  defp curl_cmd(method, url, body) when is_map(body) do
    json = Jason.encode!(body) |> String.replace("'", "'\\''")

    ~s(curl -sS -w '\\nHTTP_STATUS:%{http_code}\\n' -X #{method} ) <>
      ~s(-H 'Content-Type: application/json' -d '#{json}' #{url})
  end

  defp parse_http_response(out) do
    case Regex.run(~r/^HTTP_STATUS:(\d+)$/m, out) do
      [_, status_str] ->
        status = String.to_integer(status_str)
        body = Regex.replace(~r/\nHTTP_STATUS:\d+\n?$/, out, "")

        cond do
          status in 200..299 ->
            case body do
              "" -> {:ok, nil}
              _ -> Jason.decode(body)
            end

          true ->
            {:error, {:http, status, body}}
        end

      nil ->
        {:error, {:no_status_in_response, out}}
    end
  end

  @doc "Spawn a VM via POST /vms. Opts are merged into the request body."
  def spawn_vm(opts \\ %{}) do
    api("POST", "/vms", opts)
  end

  @doc "Get VM by ID."
  def vm_info(vm_id), do: api("GET", "/vms/#{vm_id}")

  @doc "List all VMs."
  def vm_list, do: api("GET", "/vms")

  @doc "Execute a command in a VM via POST /vms/:id/exec."
  def vm_exec(vm_id, command) do
    api("POST", "/vms/#{vm_id}/exec", %{command: command})
  end

  @doc "Stop a VM."
  def vm_stop(vm_id), do: api("DELETE", "/vms/#{vm_id}")

  @doc "Poll `/health` until it returns 2xx or timeout."
  @spec wait_for_mjolnir_up(timeout :: non_neg_integer()) :: :ok | {:error, :timeout}
  def wait_for_mjolnir_up(timeout_ms \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_health(deadline)
  end

  defp do_wait_health(deadline) do
    case api("GET", "/health") do
      {:ok, _} ->
        :ok

      {:error, _} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(500)
          do_wait_health(deadline)
        else
          {:error, :timeout}
        end
    end
  end

  @doc """
  Poll `GET /vms/:id` until it returns successfully (i.e. the VM has been
  rehydrated by Mjolnir.Reconcile), or timeout.
  """
  @spec wait_for_vm(String.t(), timeout :: non_neg_integer()) ::
          {:ok, map()} | {:error, :timeout}
  def wait_for_vm(vm_id, timeout_ms \\ 90_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_vm(vm_id, deadline)
  end

  defp do_wait_vm(vm_id, deadline) do
    case vm_info(vm_id) do
      {:ok, info} ->
        {:ok, info}

      {:error, _} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1000)
          do_wait_vm(vm_id, deadline)
        else
          {:error, :timeout}
        end
    end
  end

  @doc """
  Named chaos actions. Keeps the test DSL tight: `chaos(:restart_mjolnir)`.
  """
  @spec chaos(atom()) :: :ok | {:error, term()}
  def chaos(:restart_mjolnir) do
    case ssh("systemctl restart mjolnir") do
      {_, 0} -> :ok
      {out, code} -> {:error, {:restart_failed, code, String.trim(out)}}
    end
  end

  def chaos(:sigkill_beam) do
    # pkill returns 1 if no process matched — treat that as failure (mjolnir
    # isn't running?), but otherwise 0 means "killed at least one match".
    case ssh("pkill -9 beam.smp") do
      {_, 0} -> :ok
      {out, code} -> {:error, {:sigkill_failed, code, String.trim(out)}}
    end
  end

  def chaos({:tap_down, vm_id}) when is_binary(vm_id) do
    # Deterministic TAP name: "mj-" + first 8 chars of UUID, per Mjolnir.Network.tap_name/1
    tap = "mj-" <> String.slice(vm_id, 0, 8)

    case ssh("ip link set #{tap} down") do
      {_, 0} -> :ok
      {out, code} -> {:error, {:tap_down_failed, code, String.trim(out)}}
    end
  end

  def chaos({:tap_up, vm_id}) when is_binary(vm_id) do
    tap = "mj-" <> String.slice(vm_id, 0, 8)

    case ssh("ip link set #{tap} up") do
      {_, 0} -> :ok
      {out, code} -> {:error, {:tap_up_failed, code, String.trim(out)}}
    end
  end

  def chaos({:sigkill_ch, vm_id}) when is_binary(vm_id) do
    # Kill the cloud-hypervisor process for one specific VM (not all of them).
    # The --api-socket arg carries the VM UUID, so pkill -f can match exactly.
    case ssh("pkill -9 -f 'cloud-hypervisor.*#{vm_id}'") do
      {_, 0} -> :ok
      {_, 1} -> {:error, :no_process_matched}
      {out, code} -> {:error, {:sigkill_failed, code, String.trim(out)}}
    end
  end

  def chaos(:reboot) do
    # systemctl reboot returns quickly and schedules the reboot asynchronously.
    # SSH connection will drop mid-command; treat non-zero exit as OK here
    # since the disconnect itself is a success signal.
    _ = ssh("systemctl reboot")
    :ok
  end

  @doc """
  Poll until SSH is answering again after a reboot. The host may reject
  connections with "Connection refused" for 30-60s while boot progresses.
  """
  @spec wait_for_ssh(timeout :: non_neg_integer()) :: :ok | {:error, :timeout}
  def wait_for_ssh(timeout_ms \\ 180_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_ssh(deadline)
  end

  defp do_wait_ssh(deadline) do
    # -o ConnectTimeout=5 keeps each probe short so we spend the timeout
    # budget on retries rather than waiting on one doomed handshake.
    {_out, code} =
      System.cmd(
        "ssh",
        [
          "-o",
          "ConnectTimeout=5",
          "-o",
          "StrictHostKeyChecking=accept-new",
          host(),
          "true"
        ],
        stderr_to_stdout: true
      )

    if code == 0 do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(2_000)
        do_wait_ssh(deadline)
      else
        {:error, :timeout}
      end
    end
  end
end
