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

    with {:ok, sock} <- :gen_tcp.connect({:local, path}, 0, opts, timeout),
         :ok <- :gen_tcp.send(sock, "CONNECT 5000\n"),
         {:ok, "OK" <> _} <- :gen_tcp.recv(sock, 0, timeout),
         :ok <- :gen_tcp.send(sock, Protocol.encode(ping)),
         {:ok, <<_ch::8, len::big-32>>} <- :gen_tcp.recv(sock, 5, timeout),
         {:ok, body} <- :gen_tcp.recv(sock, len, timeout),
         :ok <- :gen_tcp.close(sock),
         {:ok, %{"type" => "pong"}} <- Jason.decode(body) do
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
