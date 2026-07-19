defmodule Mjolnir.Health.TcpLiveness do
  @moduledoc """
  Corroborating liveness probe that is **independent of the vsock guest agent**.

  Every per-VM check in `Mjolnir.Health` (`GuestAgentPing`, `VsockConnection`,
  `IrohConnection`, `GuestNetwork`) reaches the guest through the vsock
  guest-agent channel. If that single channel wedges — the agent process hangs,
  the vsock socket rots (the mjolnir-8ie signature) — *all four* probes fail and
  `Mjolnir.Health.roll_up/1` rolls the VM up to `:dead`, even though the guest
  kernel is running and the app is happily serving HTTP over TCP via the gateway
  (`gateway → guest_ip:port`).

  This probe closes that blind spot. It TCP-connects to the guest's app port(s)
  over the TAP link — the exact path the gateway uses — and never touches vsock.

  ## Interpreting the result

  A TCP `connect` to `guest_ip` tells us about the guest's *kernel and network
  stack*, not the guest agent:

  - **SYN-ACK** (`{:ok, sock}`) — a listener accepted us. The VM is alive.
  - **RST** (`{:error, :econnrefused}`) — the guest kernel actively refused the
    port. Nothing is listening there, but the kernel, TAP link, host `/32` route
    and the guest's network stack are all up: **the VM is alive**.
  - **timeout / host- or net-unreachable** — no response at all. This
    corroborates that the VM is genuinely gone.

  Returns `:alive | :unreachable | :unknown`. `:unknown` means we could not even
  attempt a probe (no `guest_ip`, no candidate ports) — the caller should treat
  that as "no corroboration available" and fall back to the vsock verdict.
  """

  require Logger

  @default_port 3000
  @default_timeout_ms 2_000

  @type liveness :: :alive | :unreachable | :unknown

  @doc """
  Probe the guest's app port(s) over TCP. See the module doc for semantics.

  Options (all optional; used for testing and tuning):

  - `:ports` — explicit list of ports to try. Defaults to the ports registered
    for this VM in `Mjolnir.Deploy.Registry` plus `#{@default_port}`.
  - `:timeout_ms` — per-connect timeout (default `#{@default_timeout_ms}`).
  - `:connect` — a 3-arity `fn addr, port, timeout -> :ok | {:error, reason}`
    used in place of `:gen_tcp.connect`. Lets the logic be unit-tested without a
    real socket.
  """
  @spec probe(Mjolnir.VM.t(), keyword()) :: liveness()
  def probe(vm, opts \\ [])

  def probe(%Mjolnir.VM{net_config: %{guest_ip: guest_ip}} = vm, opts)
      when is_binary(guest_ip) and guest_ip != "" do
    ports = Keyword.get_lazy(opts, :ports, fn -> candidate_ports(vm) end)

    case ports do
      [] ->
        :unknown

      ports ->
        timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
        connect = Keyword.get(opts, :connect, &default_connect/3)
        addr = parse_addr(guest_ip)

        # Alive if *any* candidate port proves the network stack is up.
        if Enum.any?(ports, fn port -> alive_on_port?(connect, addr, port, timeout) end) do
          :alive
        else
          :unreachable
        end
    end
  end

  # No guest_ip — nothing to corroborate against.
  def probe(_vm, _opts), do: :unknown

  # --- internals ---

  defp alive_on_port?(connect, addr, port, timeout) do
    case connect.(addr, port, timeout) do
      # A listener accepted us.
      :ok ->
        true

      # An RST from the guest kernel still proves it is alive (see moduledoc).
      {:error, :econnrefused} ->
        true

      # Genuine "nobody home" signals — do not prove liveness.
      {:error, reason} when reason in [:timeout, :ehostunreach, :enetunreach, :ehostdown] ->
        false

      # Anything else (e.g. local :emfile / config error): be conservative and
      # treat as no-proof, but surface it — a spurious error here must never be
      # allowed to *manufacture* a false "alive".
      {:error, other} ->
        Logger.debug("TcpLiveness: connect #{inspect(addr)}:#{port} errored: #{inspect(other)}")
        false
    end
  end

  defp default_connect(addr, port, timeout) do
    case :gen_tcp.connect(addr, port, [:binary, active: false], timeout) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, _} = err ->
        err
    end
  end

  # gen_tcp accepts an IP tuple or a charlist hostname; prefer a parsed tuple.
  defp parse_addr(ip) do
    charlist = String.to_charlist(ip)

    case :inet.parse_address(charlist) do
      {:ok, tuple} -> tuple
      {:error, _} -> charlist
    end
  end

  # Ports this VM's app is known to listen on, drawn from the Deploy registry,
  # plus the platform default. Best-effort: the registry may be absent (tests) or
  # empty, in which case we still probe the default port.
  defp candidate_ports(%Mjolnir.VM{id: vm_id}) do
    registry_ports =
      try do
        Mjolnir.Deploy.Registry.list()
        |> Enum.filter(fn e -> e.service_vm_id == vm_id and is_integer(e.port) end)
        |> Enum.map(& &1.port)
      rescue
        _ -> []
      catch
        _, _ -> []
      end

    (registry_ports ++ [@default_port])
    |> Enum.uniq()
  end
end
