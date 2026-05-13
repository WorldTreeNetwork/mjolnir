defmodule Mjolnir.Forge.Host do
  @moduledoc """
  GenServer managing reconciliation for a single host. v0 supports `:local`
  transport only (`host == "self"`) — SSH is a v1 ticket.

  ## v0 behaviour

  - `plan/1` is the on-demand reconcile: observe → diff → upsert store rows
    → return entries. No mutation of the host.
  - `apply/2` performs writes for the given keys (or `:all_safe` for every
    `:new` / `:drifted` / `:missing` / `:prune`). `:conflict` and
    `:unmanaged` are never auto-resolved — they require explicit human
    action via `adopt/2` or `ignore/2`.
  - The periodic reconcile timer is intentionally off in v0 (the decision
    on first-apply blast radius lands as: `auto_apply` defaults to `false`,
    user must opt in).
  """

  use GenServer
  require Logger

  alias Mjolnir.Forge.{Declarations, Diff, Resource, Store}
  alias Mjolnir.Forge.Store.Record

  @type host :: String.t()

  defstruct host: "self",
            transport: :local,
            interval_ms: 60_000,
            auto_apply: false,
            timer_ref: nil

  ## Public API

  def start_link(opts) do
    host = Keyword.fetch!(opts, :host)
    GenServer.start_link(__MODULE__, opts, name: name_for(host))
  end

  def name_for(host), do: {:via, Registry, {Mjolnir.Forge.HostRegistry, host}}

  @doc "Re-observe and recompute diff. Returns the diff entries."
  @spec plan(host()) :: [Diff.entry()]
  def plan(host), do: GenServer.call(name_for(host), :plan, 30_000)

  @doc """
  Apply selected entries. `keys` is a list of `{kind_module, id}` or the
  atom `:all_safe` to apply every `:new`/`:drifted`/`:missing`/`:prune`.
  Returns a list of `{key, :ok | {:error, reason}}`.
  """
  @spec apply(host(), [{module(), String.t()}] | :all_safe) ::
          [{{module(), String.t()}, :ok | {:error, term()}}]
  def apply(host, keys), do: GenServer.call(name_for(host), {:apply, keys}, :infinity)

  ## GenServer

  @impl true
  def init(opts) do
    state = %__MODULE__{
      host: Keyword.fetch!(opts, :host),
      transport: Keyword.get(opts, :transport, :local),
      interval_ms: Keyword.get(opts, :interval_ms, 60_000),
      auto_apply: Keyword.get(opts, :auto_apply, false)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:plan, _from, state) do
    entries = do_plan(state)
    {:reply, entries, state}
  end

  def handle_call({:apply, keys}, _from, state) do
    entries = do_plan(state)
    selected = select_for_apply(entries, keys)
    results = Enum.map(selected, &apply_entry(&1, state))
    # Re-plan after to refresh store rows.
    _ = do_plan(state)
    {:reply, results, state}
  end

  ## Internals

  defp do_plan(%__MODULE__{host: host, transport: transport}) do
    declared = Declarations.declared_map(host)
    owned = Store.owned_map(host)
    observed = observe_all(declared, owned, transport, host)

    entries = Diff.compute(declared, owned, observed)
    Enum.each(entries, &upsert(&1, host))
    entries
  end

  defp observe_all(declared, owned, transport, host) do
    keys = MapSet.union(MapSet.new(Map.keys(declared)), MapSet.new(Map.keys(owned)))

    for {kind, id} = key <- keys, into: %{} do
      result =
        case Resource.observe(kind, transport, host, id) do
          {:present, _} = ok -> ok
          :missing -> :missing
          {:error, reason} ->
            Logger.warning(
              "Forge.Host #{host}: observe #{inspect(kind)}/#{id} failed: #{inspect(reason)}"
            )

            :missing
        end

      {key, result}
    end
  end

  defp upsert(%{kind: kind, id: id, status: status} = entry, host) do
    now = DateTime.utc_now()
    existing =
      case Store.get(host, kind.kind(), id) do
        {:ok, r} -> r
        :not_found -> nil
      end

    record =
      Record.new(host, kind.kind(), id,
        status: status,
        declared_hash: entry.declared_hash,
        owned_hash: entry.owned_hash || (existing && existing.owned_hash),
        observed_hash: entry.observed_hash,
        observed_at: now,
        applied_at: existing && existing.applied_at,
        inserted_at: (existing && existing.inserted_at) || now
      )

    Store.put(record)
  end

  defp select_for_apply(entries, :all_safe) do
    Enum.filter(entries, &(&1.status in [:new, :drifted, :missing, :prune]))
  end

  defp select_for_apply(entries, keys) when is_list(keys) do
    set = MapSet.new(keys)
    Enum.filter(entries, fn e -> MapSet.member?(set, {e.kind, e.id}) end)
  end

  defp apply_entry(%{kind: kind, id: id}, %{transport: :ssh}) do
    {{kind, id}, {:error, :ssh_transport_not_implemented_yet}}
  end

  defp apply_entry(%{status: :prune, kind: kind, id: id}, %{host: host}) do
    case kind.delete(host, id) do
      :ok ->
        _ = Store.delete(host, kind.kind(), id)
        {{kind, id}, :ok}

      err ->
        {{kind, id}, err}
    end
  end

  defp apply_entry(
         %{status: s, kind: kind, id: id, declared_content: content, declared_hash: hash},
         %{host: host}
       )
       when s in [:new, :drifted, :missing] and not is_nil(content) do
    case kind.apply(host, id, content) do
      :ok ->
        now = DateTime.utc_now()

        record =
          case Store.get(host, kind.kind(), id) do
            {:ok, r} -> %{r | owned_hash: hash, applied_at: now, status: :converged}
            :not_found ->
              Record.new(host, kind.kind(), id,
                status: :converged,
                declared_hash: hash,
                owned_hash: hash,
                observed_hash: hash,
                applied_at: now,
                observed_at: now
              )
          end

        _ = Store.put(record)
        {{kind, id}, :ok}

      err ->
        {{kind, id}, err}
    end
  end

  defp apply_entry(%{kind: kind, id: id, status: status}, _state) do
    {{kind, id}, {:error, {:unsupported_apply_status, status}}}
  end
end
