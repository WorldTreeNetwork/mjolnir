defmodule Mjolnir.Health.GuestAgentPing do
  @moduledoc """
  L0 check: can we ping the guest agent over vsock and get a pong?

  Purely diagnostic — there is no heal at L0 (the next tier up restarts
  the vsock connection, which is what "healing" a ping failure means).
  """

  @behaviour Mjolnir.Health.Check

  alias Mjolnir.Vsock.Protocol

  @impl true
  def level, do: 0

  @impl true
  def name, do: "guest_agent_ping"

  @impl true
  def probe(%Mjolnir.VM{vsock_path: nil}), do: {:dead, :no_vsock_path}

  def probe(%Mjolnir.VM{vsock_path: path}) do
    ping_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    ping = %{"type" => "ping", "id" => ping_id}
    timeout = 2_000

    opts = [:binary, active: false, packet: :raw]

    case :gen_tcp.connect({:local, path}, 0, opts, timeout) do
      {:ok, sock} ->
        result = do_probe(sock, ping, timeout)
        :gen_tcp.close(sock)
        result

      {:error, reason} ->
        {:dead, reason}
    end
  end

  # Uses Protocol.read_json_response (mjolnir-pry) rather than reading "the
  # next frame" directly: a fresh vsock connection makes the guest agent
  # spawn a new syslog forwarder, whose backlog can win the race against
  # the pong and land on channel 2 first. read_json_response skips it.
  defp do_probe(sock, ping, timeout) do
    with :ok <- :gen_tcp.send(sock, "CONNECT 5000\n"),
         {:ok, "OK" <> _} <- :gen_tcp.recv(sock, 0, timeout),
         :ok <- :gen_tcp.send(sock, Protocol.encode(ping)),
         {:ok, %{"type" => "pong"}} <- Protocol.read_json_response(sock, timeout) do
      :ok
    else
      {:error, :timeout} -> {:dead, :timeout}
      {:error, reason} -> {:dead, reason}
      {:ok, other} -> {:degraded, {:unexpected_response, other}}
    end
  end

  @impl true
  def heal(_vm), do: {:error, :no_heal_for_l0}
end
