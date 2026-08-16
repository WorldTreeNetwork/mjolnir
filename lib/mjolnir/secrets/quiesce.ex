defmodule Mjolnir.Secrets.Quiesce do
  @moduledoc """
  Wipe the LUKS volume key from guest RAM before a memory snapshot.

  A memory snapshot is the guest's full address space. If the secrets volume
  is unlocked, the dm-crypt DEK lands in `@snapshots/<name>.mem` in
  cleartext. There is no region of RAM a snapshot can omit that the guest
  still needs at thaw — anything reachable is captured; anything not
  captured is unreachable.

  `cryptsetup luksSuspend` suspends the mapper **and wipes the volume key
  from kernel memory**. The LUKS container is a loopback file, not root, so
  this cannot deadlock the guest.

  Freeze must call `suspend/2` while vCPUs are still running. Thaw calls
  `resume/3`, or the existing `inject_secrets` path (which resumes a
  suspended mapper) after `vm.resume`.
  """

  require Logger

  alias Mjolnir.Vsock.Protocol

  @default_timeout_ms 10_000

  @doc "Build the `suspend_secrets` request."
  @spec suspend_request(keyword()) :: map()
  def suspend_request(opts \\ []) do
    Protocol.suspend_secrets_request(opts)
  end

  @doc "Build the `resume_secrets` request."
  @spec resume_request(String.t(), keyword()) :: map()
  def resume_request(passphrase, opts \\ []) when is_binary(passphrase) do
    Protocol.resume_secrets_request(passphrase, opts)
  end

  @doc """
  Ask the guest to wipe the LUKS volume key.

  `vsock` is a host-side vsock UDS path. Returns
  `{:ok, %{suspended: boolean}}` — `false` means nothing was open, which is
  success (nothing to hide). Every other outcome is an error: a secrets VM
  whose key was not wiped must not be snapshotted.
  """
  @spec suspend(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def suspend(vsock_path, opts \\ []) when is_binary(vsock_path) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case oneshot(vsock_path, suspend_request(opts), timeout) do
      {:ok, response} -> interpret_suspend(response)
      {:error, reason} -> {:error, {:suspend_transport_failed, reason}}
    end
  end

  @doc """
  Re-install the volume key after thaw.

  Prefer this when the caller already knows the mapper is open-but-suspended.
  `inject_secrets` also resumes; this is the explicit form.
  """
  @spec resume(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def resume(vsock_path, passphrase, opts \\ [])
      when is_binary(vsock_path) and is_binary(passphrase) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case oneshot(vsock_path, resume_request(passphrase, opts), timeout) do
      {:ok, response} -> interpret_resume(response)
      {:error, reason} -> {:error, {:resume_transport_failed, reason}}
    end
  end

  @doc """
  Classify a `suspend_secrets_response`. Public so the fail-closed policy is
  testable without a live guest.
  """
  @spec interpret_suspend(map()) :: {:ok, map()} | {:error, term()}
  def interpret_suspend(%{"type" => "suspend_secrets_response", "ok" => true} = response) do
    {:ok, %{suspended: response["suspended"] == true}}
  end

  def interpret_suspend(%{"type" => "suspend_secrets_response", "ok" => false} = response) do
    {:error, {:suspend_refused, response["error"]}}
  end

  def interpret_suspend(%{"type" => "error", "error" => error}) do
    {:error, {:suspend_unsupported_by_agent, error}}
  end

  def interpret_suspend(other), do: {:error, {:suspend_unexpected_response, other}}

  @doc """
  Classify a `resume_secrets_response`. Same fail-closed policy as suspend:
  an old agent or a refusal is an error, not a silent skip.
  """
  @spec interpret_resume(map()) :: :ok | {:error, term()}
  def interpret_resume(%{"type" => "resume_secrets_response", "ok" => true}), do: :ok

  def interpret_resume(%{"type" => "resume_secrets_response", "ok" => false} = response) do
    {:error, {:resume_refused, response["error"]}}
  end

  def interpret_resume(%{"type" => "error", "error" => error}) do
    {:error, {:resume_unsupported_by_agent, error}}
  end

  def interpret_resume(other), do: {:error, {:resume_unexpected_response, other}}

  defp oneshot(vsock_path, request, timeout) do
    with {:ok, sock} <- vsock_connect(vsock_path, timeout) do
      try do
        :ok = :gen_tcp.send(sock, Protocol.encode(request))
        Protocol.read_json_response(sock, timeout)
      after
        :gen_tcp.close(sock)
      end
    end
  end

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
end
