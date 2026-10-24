defmodule Mjolnir.Thaw.Publish do
  @moduledoc """
  Reachability gate for a VM that `MemorySnapshot.thaw/3` has already resumed.

  `Mjolnir.VM` calls `run/1` from the thaw attach path, before a PTY, a
  ticket, or a gateway route is written and before the VM is marked
  `:running` (`:vm_started` is what the gateway reconciler listens for).

  `run/1` is the whole decision. It calls the reseed, then the wall-clock
  step, and only then the Iroh probe. A vsock boot ping is recorded and
  ignored: an agent that answers `ping` is not a healthy thaw.

  A clock or reseed failure returns `{:error, reason}` and publishes nothing.
  When Iroh is enabled, `run/1` then classifies the reachability probe and
  publishes only on `ready: true` plus a node id. A vsock ping is not that
  probe. Iroh disabled (not the default) skips the probe: there is no
  endpoint to dial, and the thaw still requires reseed and the wall step.
  """

  @doc """
  Run the publish probes and decide.

  `ctx` keys:

    * `:reseed` — zero-arity function, `:ok` or `{:error, reason}`
    * `:clock` — zero-arity function, `:ok` or `{:error, reason}`
    * `:iroh` — zero-arity function, used only when `:enable_iroh` is true.
      Not called when the clock or the reseed failed. Its return value is
      classified by `classify_iroh/1` (the map `await_iroh_ready` returns,
      `nil`, or an error tuple).
    * `:enable_iroh` — boolean
    * `:vmgenid_record` — immutable capture metadata
    * `:vmgenid` — zero-arity guest device observation, `{:ok, id}` or `:missing`
    * `:vsock_only` — suppress gateway and ticket publication for a second guest
    * `:boot_ping` — optional, ignored by the decision
  """
  @spec run(map()) :: {:ok, map()} | {:error, term()}
  def run(ctx) when is_map(ctx) do
    with :ok <- invoke(ctx.reseed),
         :ok <- invoke(ctx.clock),
         {:ok, generation} <-
           Mjolnir.Thaw.Vmgenid.verify(
             Map.get(ctx, :vmgenid_record),
             invoke(Map.get(ctx, :vmgenid))
           ) do
      iroh =
        if Map.get(ctx, :enable_iroh, false) and not Map.get(ctx, :vsock_only, false) do
          classify_iroh(invoke(Map.get(ctx, :iroh)))
        else
          :disabled
        end

      decision =
        decide(%{
          boot_ping: Map.get(ctx, :boot_ping, :unspecified),
          reseed: :ok,
          clock: :ok,
          monotonic_stepped: false,
          iroh: iroh,
          enable_iroh: Map.get(ctx, :enable_iroh, false) and not Map.get(ctx, :vsock_only, false)
        })

      case decision do
        {:ok, result} ->
          {:ok,
           Map.merge(result, %{
             vmgenid: generation,
             published: not Map.get(ctx, :vsock_only, false)
           })}

        error ->
          error
      end
    end
  end

  @doc """
  How long the thaw waits for the guest Iroh endpoint, in milliseconds.

  Same bound the attach path used to poll with, now the definition of the
  probe: past this, the endpoint is unreachable and the thaw is not published.
  """
  @spec iroh_timeout_ms() :: pos_integer()
  def iroh_timeout_ms, do: 5_000

  @doc """
  Success is a guest Iroh endpoint that reports `ready: true` and a non-empty
  node id within `iroh_timeout_ms/0`. That node id is what becomes the
  connection ticket. `nil`, `ready: false`, a missing node id, and any error
  are unreachable. A vsock pong is not a value this function accepts.
  """
  @spec classify_iroh(term()) :: {:ok, map()} | {:error, term()}
  def classify_iroh(%{ready: true, node_id: id} = info) when is_binary(id) and id != "" do
    {:ok, info}
  end

  def classify_iroh({:ok, %{ready: true, node_id: id} = info}) when is_binary(id) and id != "" do
    {:ok, info}
  end

  def classify_iroh(nil), do: {:error, :iroh_unreachable}

  def classify_iroh(%{ready: false}), do: {:error, :iroh_not_ready}

  def classify_iroh({:ok, %{ready: false}}), do: {:error, :iroh_not_ready}

  def classify_iroh({:error, reason}), do: {:error, {:iroh_probe_failed, reason}}

  def classify_iroh(other), do: {:error, {:iroh_probe_failed, other}}

  @doc """
  Pure publish decision.

  Requires a confirmed reseed, a confirmed wall-clock step, and
  `monotonic_stepped: false`. `:boot_ping` is not consulted. With Iroh
  enabled, the classified probe must be `{:ok, info}`.
  """
  @spec decide(map()) :: {:ok, map()} | {:error, :unpublished}
  def decide(%{
        reseed: :ok,
        clock: :ok,
        monotonic_stepped: false,
        enable_iroh: true,
        iroh: {:ok, info}
      }) do
    {:ok,
     %{
       published: true,
       monotonic_stepped: false,
       iroh: info,
       enable_iroh: true
     }}
  end

  def decide(%{reseed: :ok, clock: :ok, monotonic_stepped: false, enable_iroh: false}) do
    {:ok,
     %{
       published: true,
       monotonic_stepped: false,
       iroh: nil,
       enable_iroh: false
     }}
  end

  def decide(probes) when is_map(probes), do: {:error, :unpublished}

  @doc """
  Health of a probe map. `:healthy` only when `decide/1` would publish.
  A vsock ping does not flip this. There is no live peer in the unit test:
  pass a failed or stubbed probe result.
  """
  @spec health(map()) :: :healthy | :unhealthy
  def health(probes) when is_map(probes) do
    case decide(probes) do
      {:ok, _} -> :healthy
      {:error, :unpublished} -> :unhealthy
    end
  end

  defp invoke(fun) when is_function(fun, 0), do: fun.()
  defp invoke(_), do: nil
end
