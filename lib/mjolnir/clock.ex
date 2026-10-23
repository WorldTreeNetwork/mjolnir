defmodule Mjolnir.Clock do
  @moduledoc """
  Steps a restored guest's wall clock to host time before the VM is published.

  Cloud Hypervisor restores the KVM clock from the snapshot (CH #7932) and
  its REST API has no call that rewrites that clock while vCPUs are still
  paused. `MemorySnapshot.thaw/3` has therefore already resumed the guest by
  the time this module runs. The step is a guest-agent `set_wall_time`, and
  `Mjolnir.Thaw.Publish` will not publish a PTY, ticket, or gateway route
  until the guest confirms the new wall time.

  The request names `CLOCK_REALTIME` only. Park duration is not added to
  `CLOCK_MONOTONIC` (it is not a settable clock, and a freeze is not suspend).
  `CLOCK_BOOTTIME` is not stepped either: that injection is a kernel
  timekeeping path this agent cannot reach.

  Already-running processes inside the guest can still read the snapshot
  clock in the gap between `vm.resume` and this confirmation. Callers outside
  the guest cannot: a failed or unconfirmed step fails the thaw the same way
  a failed entropy reseed does.
  """

  require Logger

  alias Mjolnir.Vsock.Connection

  # The guest reads the clock back after `clock_settime`. Two seconds covers
  # the round trip without accepting a guest that is still hours behind.
  @skew_secs 2

  @default_timeout_ms 10_000

  @doc """
  Host wall time as `{unix_seconds, nanoseconds}`.

  This is the value sent to the guest. It is the host's current
  `CLOCK_REALTIME`, not the snapshot's timestamp plus how long the VM was
  parked.
  """
  @spec host_wall() :: {integer(), integer()}
  def host_wall do
    ns = System.system_time(:nanosecond)
    {div(ns, 1_000_000_000), rem(ns, 1_000_000_000)}
  end

  @doc """
  Build the `set_wall_time` request.

  The payload has no monotonic or boot-time field. A guest that stepped
  either would be a different request, and `interpret/2` rejects a response
  that claims `monotonic_stepped: true`.
  """
  @spec request(integer(), integer(), String.t() | nil) :: map()
  def request(realtime_secs, realtime_nsec, id \\ nil)
      when is_integer(realtime_secs) and is_integer(realtime_nsec) do
    %{
      "type" => "set_wall_time",
      "id" => id || UUID.uuid4(),
      "realtime_secs" => realtime_secs,
      "realtime_nsec" => realtime_nsec
    }
  end

  @doc """
  Ask the guest to set its wall clock to host time.

  Returns `:ok` only when the guest confirms a `CLOCK_REALTIME` within
  #{@skew_secs}s of the time we sent and explicitly reports that monotonic
  time was not stepped.

  ## Options

    - `:timeout_ms` — how long to wait (default #{@default_timeout_ms})
    - `:wall` — `{secs, nsec}` to send (tests only; production calls `host_wall/0`)
  """
  @spec step(pid(), keyword()) :: :ok | {:error, term()}
  def step(conn, opts \\ []) do
    {secs, nsec} = Keyword.get_lazy(opts, :wall, &host_wall/0)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case Connection.send_request(conn, request(secs, nsec), timeout) do
      {:ok, response} -> interpret(response, secs)
      {:error, reason} -> {:error, {:clock_transport_failed, reason}}
    end
  end

  @doc """
  Classify a guest's `set_wall_time_response` against the unix seconds we asked for.

  Public so the fail-closed policy is testable without a live guest. A guest
  that answers `ok: true` while still reporting snapshot time is refused.
  """
  @spec interpret(map(), integer()) :: :ok | {:error, term()}
  def interpret(response, requested_secs) when is_integer(requested_secs) do
    case response do
      %{
        "type" => "set_wall_time_response",
        "ok" => true,
        "monotonic_stepped" => false,
        "realtime_secs" => got
      }
      when is_integer(got) ->
        if abs(got - requested_secs) <= @skew_secs do
          Logger.info("Guest wall clock set to #{got}")
          :ok
        else
          {:error, {:clock_not_host_time, got, requested_secs}}
        end

      %{"type" => "set_wall_time_response", "monotonic_stepped" => true} ->
        {:error, :monotonic_stepped}

      %{"type" => "set_wall_time_response", "ok" => false} = response ->
        {:error, {:clock_refused, response["error"]}}

      %{"type" => "set_wall_time_response"} ->
        {:error, {:clock_unconfirmed, response}}

      %{"type" => "error", "error" => error} ->
        {:error, {:clock_unsupported_by_agent, error}}

      other ->
        {:error, {:clock_unexpected_response, other}}
    end
  end
end
