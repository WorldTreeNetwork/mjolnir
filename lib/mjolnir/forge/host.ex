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

  alias Mjolnir.Forge.{Authoring, Declarations, Diff, Events, Resource, Store}
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

  @doc """
  Recompute and return the single diff entry for `{kind_module, id}` (with
  materialized content), or `nil` if the resource is neither declared nor
  owned. Emits no events — this is a detail fetch for the diff view.
  """
  @spec diff_one(host(), {module(), String.t()}) :: Diff.entry() | nil
  def diff_one(host, key), do: GenServer.call(name_for(host), {:diff_one, key}, 30_000)

  @doc """
  Adopt an unmanaged resource: re-observe it, author a `.adopted.exs`
  declaration from the observed content, reload declarations, and take
  ownership. Returns `:ok` or `{:error, reason}`. Emits an `:adopt` event.
  """
  @spec adopt(host(), {module(), String.t()}) :: :ok | {:error, term()}
  def adopt(host, key), do: GenServer.call(name_for(host), {:adopt, key}, :infinity)

  @doc """
  Mark a resource `:ignored` so it stops being surfaced as `:unmanaged`. The
  mark is sticky across re-plans until the resource becomes declared. Emits an
  `:ignore` event.
  """
  @spec ignore(host(), {module(), String.t()}) :: :ok | {:error, term()}
  def ignore(host, key), do: GenServer.call(name_for(host), {:ignore, key}, :infinity)

  @doc """
  Host-wide discovery: enumerate every enumerable kind, keep the ids that are
  neither declared nor owned, observe + classify them (`:unmanaged`), and
  upsert them into the store so `/state` and the TUI can surface them. Returns
  the discovered entries. Emits no events — discovery is a read.
  """
  @spec discover(host()) :: [Diff.entry()]
  def discover(host), do: GenServer.call(name_for(host), :discover, 60_000)

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
  def handle_call(:plan, _from, %__MODULE__{host: host} = state) do
    entries = do_plan(state)
    # Observability: one probe summary + a drift event per out-of-sync resource.
    # Emitted only here, not from the internal re-plan inside :apply, so a
    # single apply doesn't double-report drift it just resolved. Ignored
    # resources are suppressed — the user already said "leave it alone".
    _ = Events.probe(host, entries)
    _ = Events.drift(host, Enum.reject(entries, &ignored?(host, &1)))
    {:reply, entries, state}
  end

  def handle_call(
        {:diff_one, key},
        _from,
        %__MODULE__{host: host, transport: transport} = state
      ) do
    # Single-key diff: observe the named resource directly rather than filtering
    # do_plan, so it works even for resources the plan doesn't enumerate (an
    # undeclared, unowned unit the user wants to inspect/adopt).
    entry =
      single_diff(Declarations.declared_map(host), Store.owned_map(host), transport, host, key)

    {:reply, entry, state}
  end

  def handle_call(:discover, _from, %__MODULE__{host: host, transport: transport} = state) do
    declared = Declarations.declared_map(host)
    owned = Store.owned_map(host)
    known = MapSet.union(MapSet.new(Map.keys(declared)), MapSet.new(Map.keys(owned)))

    entries =
      for mod <- Resource.enumerable_kinds(),
          id <- Resource.enumerate(mod, transport, host),
          key = {mod, id},
          not MapSet.member?(known, key),
          entry = single_diff(declared, owned, transport, host, key),
          not is_nil(entry) do
        entry
      end

    Enum.each(entries, &upsert(&1, host))
    {:reply, entries, state}
  end

  def handle_call(
        {:adopt, {kind, id} = key},
        _from,
        %__MODULE__{host: host, transport: transport} = state
      ) do
    reply =
      with :ok <- refuse_if_hand_managed(host, kind, id),
           {:present, content} <- Resource.observe(kind, transport, host, id),
           {:ok, _path} <- Authoring.write(host, kind, id, content),
           :ok <- Declarations.reload() do
        # The resource is now declared and matches the host → `:converged`,
        # which apply_entry takes ownership of (no side effects). Route through
        # the apply path so the :adopt event + store update stay consistent.
        entry = do_plan(state) |> Enum.find(fn e -> {e.kind, e.id} == key end)

        case entry do
          nil ->
            {:error, :not_present_after_adopt}

          entry ->
            {_key, outcome} = result = apply_entry(entry, state)
            _ = Events.apply_outcome(host, entry, elem(result, 1))
            _ = do_plan(state)
            outcome
        end
      else
        :missing -> {:error, :not_observed}
        {:error, _} = err -> err
      end

    {:reply, reply, state}
  end

  def handle_call({:ignore, {kind, id}}, _from, %__MODULE__{host: host} = state) do
    now = DateTime.utc_now()

    record =
      case Store.get(host, kind.kind(), id) do
        {:ok, r} -> %{r | status: :ignored}
        :not_found -> Record.new(host, kind.kind(), id, status: :ignored, observed_at: now)
      end

    reply = Store.put(record)

    _ =
      Events.emit(
        host: host,
        type: :ignore,
        kind: kind.kind(),
        resource_id: id,
        status: "ignored"
      )

    {:reply, reply, state}
  end

  def handle_call({:apply, keys}, _from, %__MODULE__{host: host} = state) do
    entries = do_plan(state)
    selected = select_for_apply(entries, keys)

    results =
      Enum.map(selected, fn entry ->
        result = apply_entry(entry, state)
        _ = Events.apply_outcome(host, entry, elem(result, 1))
        result
      end)

    # Re-plan after to refresh store rows (no events — see :plan above).
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
          {:present, _} = ok ->
            ok

          :missing ->
            :missing

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

    # A resource the user ignored stays ignored as long as it's still
    # unmanaged. Once it gains a declaration the computed status takes over.
    status = sticky_ignore(existing, status)

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

  # One resource's diff entry: pull its declared/owned slices from the
  # already-computed maps and observe it live. Shared by diff_one and discover.
  defp single_diff(declared, owned, transport, host, {kind, id} = key) do
    single_observed =
      case Resource.observe(kind, transport, host, id) do
        {:present, _} = obs -> %{key => obs}
        _ -> %{}
      end

    Diff.compute(take(declared, key), take(owned, key), single_observed)
    |> Enum.find(fn e -> e.kind == kind and e.id == id end)
  end

  # Single-entry submap: `%{key => value}` if present, else `%{}`.
  defp take(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> %{key => value}
      :error -> %{}
    end
  end

  defp sticky_ignore(%{status: :ignored}, :unmanaged), do: :ignored
  defp sticky_ignore(_existing, status), do: status

  # Adopt/overwrite may only author files Forge owns. If the resource is already
  # declared in a hand-written `.exs`, refuse rather than create a duplicate
  # `.adopted.exs` for the same key (the user should edit their file instead).
  defp refuse_if_hand_managed(host, kind, id) do
    case Declarations.source_path(host, kind.kind(), id) do
      nil -> :ok
      path -> if Authoring.forge_owned?(path), do: :ok, else: {:error, :hand_managed}
    end
  end

  defp ignored?(host, %{kind: kind, id: id}) do
    match?({:ok, %{status: :ignored}}, Store.get(host, kind.kind(), id))
  end

  defp select_for_apply(entries, :all_safe) do
    Enum.filter(entries, &(&1.status in [:new, :drifted, :missing, :prune, :converged]))
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
            {:ok, r} ->
              %{r | owned_hash: hash, applied_at: now, status: :converged}

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

  # Adopt without side-effects: declared == observed but no owned record yet.
  defp apply_entry(%{status: :converged, kind: kind, id: id, declared_hash: hash}, %{host: host}) do
    now = DateTime.utc_now()

    record =
      case Store.get(host, kind.kind(), id) do
        {:ok, r} ->
          %{r | owned_hash: hash, applied_at: now, status: :converged}

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
  end

  defp apply_entry(%{kind: kind, id: id, status: status}, _state) do
    {{kind, id}, {:error, {:unsupported_apply_status, status}}}
  end
end
