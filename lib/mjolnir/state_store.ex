defmodule Mjolnir.StateStore do
  @moduledoc """
  Durable per-VM intent store. One JSON file per VM at
  `<state_dir>/<uuid>.json`; an in-memory ETS cache mirrors the files for
  fast reads. See `docs/plans/durability.md` for the broader design.

  ## Guarantees

  - **Atomic on-disk writes**: writes go to `<uuid>.json.tmp`, are fsynced,
    then renamed over the final path. Readers never observe a partially
    written file.
  - **Cache coherence**: ETS is updated under the GenServer's serialized
    write path, after the file rename succeeds. A write that fails to reach
    disk is not reflected in ETS.
  - **Quarantine, don't discard**: files nobody can read — invalid JSON, a
    missing or malformed schema version, missing required fields — are moved to
    `<state_dir>/quarantine/` and logged. They are never silently deleted.
  - **Never quarantine a record from the future**: a file whose `schema_version`
    is a version we do not speak is *intact*, just not ours to read. It is left
    exactly where it is, and the UUID is held back from writes (see
    `unreadable/0`). Quarantining it would turn a rollback into data loss:
    quarantine *renames*, so rolling forward again would not find the file.

  ## Reads vs writes

  Reads (`get/1`, `list/0`, `list_by_intent/1`, `list_by_metadata/1`) go
  straight to ETS — concurrent, lock-free, O(1) lookups. Writes (`put/1`,
  `delete/1`, `delete_if_match/2`) go through the GenServer to serialize
  disk + ETS updates.

  ## Metadata and generations

  A record carries an opaque `metadata` map (`string => string`) that Mjolnir
  never interprets, and a monotonic `generation` counter.

  Together they let an external orchestrator manage a subset of VMs safely:

  - **select** candidates with `list_by_metadata/1`,
  - **positively identify** one by reading a full identifier back out of its
    metadata — a truncated selector is collision-*resistant*, not
    collision-*free*, so the exact-match read is what makes it safe,
  - **fence** a destructive write with `delete_if_match/2`, which refuses if
    the record changed since it was read.

  The generation is owned by this module, not by callers. `put/1` assigns
  `previous + 1` (or `1` for a new record) regardless of what the passed record
  carries. That matters because callers such as `Mjolnir.VM.build_running_record/1`
  construct a *fresh* struct on every persist; a caller-supplied generation
  would reset to 1 each time and silently void the fencing guarantee.
  """

  use GenServer
  require Logger

  alias Mjolnir.StateStore.Record

  @table __MODULE__

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Look up a record by VM UUID."
  @spec get(String.t()) :: {:ok, Record.t()} | :not_found
  def get(uuid) when is_binary(uuid) do
    case :ets.lookup(@table, resident_key(uuid)) do
      [{_key, record}] -> {:ok, record}
      [] -> :not_found
    end
  end

  @doc """
  Persist a record to disk and cache. Overwrites any existing record for the
  same UUID, and assigns the next `generation` (see moduledoc).

  Metadata is preserved across writes: a caller that rebuilds a record from live
  VM state without metadata does not thereby erase labels an orchestrator set.
  Pass metadata explicitly (or use `merge_metadata/2`) to change them.
  """
  @spec put(Record.t()) :: :ok | {:error, term()}
  def put(%Record{} = record) do
    GenServer.call(__MODULE__, {:put, record})
  end

  @doc """
  Merge `metadata` onto an existing record, bumping its generation.

  Returns the stored record so a caller can fence a later delete against the
  generation this write produced.
  """
  @spec merge_metadata(String.t(), map()) ::
          {:ok, Record.t()} | :not_found | {:error, term()}
  def merge_metadata(uuid, metadata) when is_binary(uuid) and is_map(metadata) do
    GenServer.call(
      __MODULE__,
      {:merge_metadata, resident_key(uuid), Record.normalize_metadata(metadata)}
    )
  end

  @doc "Delete a record from disk and cache. Idempotent — no error if already gone."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(uuid) when is_binary(uuid) do
    GenServer.call(__MODULE__, {:delete, resident_key(uuid)})
  end

  @doc """
  Delete a record only if its generation is exactly `generation`.

  The compare-and-delete half of the fencing contract: a caller that observed a
  record at generation N can delete it and know nothing has changed in between.

  - `:ok` — deleted, or already absent. Delete-of-absent is success, so a
    retried delete after a crash is not an error.
  - `{:error, :conflict}` — the record exists at a *different* generation.
    Something changed since the observation that authorized this delete; the
    caller must re-read and decide again, never retry blindly.
  """
  @spec delete_if_match(String.t(), pos_integer()) :: :ok | {:error, :conflict} | {:error, term()}
  def delete_if_match(uuid, generation) when is_binary(uuid) and is_integer(generation) do
    GenServer.call(__MODULE__, {:delete_if_match, resident_key(uuid), generation})
  end

  @doc "All records currently in the cache, in unspecified order."
  @spec list() :: [Record.t()]
  def list do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_uuid, record} -> record end)
  end

  @doc "All records matching the given intent."
  @spec list_by_intent(Record.intent()) :: [Record.t()]
  def list_by_intent(intent) when intent in [:running, :dormant, :stopped, :failed] do
    list() |> Enum.filter(&(&1.intent == intent))
  end

  @doc """
  All records whose metadata contains every key/value pair in `selector`.

  An empty selector matches everything, matching the convention that a filter
  with no constraints is not a filter. Callers that mean "only labelled records"
  should select on the label they care about.
  """
  @spec list_by_metadata(map()) :: [Record.t()]
  def list_by_metadata(selector) when is_map(selector) do
    normalized = Record.normalize_metadata(selector)

    list()
    |> Enum.filter(fn record ->
      Enum.all?(normalized, fn {k, v} -> Map.get(record.metadata, k) == v end)
    end)
  end

  @doc """
  UUIDs present on disk that this binary refused to read, as `%{uuid => reason}`.

  Populated when a record states a `schema_version` we do not speak — the
  signature of running an older binary than the one that wrote the state, i.e. a
  rollback. Those files are left untouched, and `put/1` / `delete/1` refuse the
  UUID so a partially-understood state directory cannot be silently overwritten
  by the older binary.

  The fix is to roll forward. Surfaced by health checks so it is visible before
  someone notices a VM missing.
  """
  @spec unreadable() :: %{String.t() => term()}
  def unreadable do
    GenServer.call(__MODULE__, :unreadable)
  end

  @doc "Reload the cache from disk. Used by tests and by `Mjolnir.Reconcile`."
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc "Configured state directory (`config :mjolnir, :state_dir`)."
  @spec state_dir() :: String.t()
  def state_dir do
    Application.fetch_env!(:mjolnir, :state_dir)
  end

  ## GenServer

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    :ok = ensure_dirs()
    {:ok, %{unreadable: load_from_disk()}}
  end

  @impl true
  def handle_call({:put, %Record{uuid: uuid} = record}, _from, state) do
    if unreadable?(state, uuid) do
      {:reply, {:error, :record_unreadable}, state}
    else
      case do_put(succeed(record)) do
        {:ok, _stored} ->
          {:reply, :ok, state}

        {:error, reason} = err ->
          Logger.error("StateStore put failed for #{uuid}: #{inspect(reason)}")
          {:reply, err, state}
      end
    end
  end

  def handle_call({:merge_metadata, uuid, metadata}, _from, state) do
    cond do
      unreadable?(state, uuid) ->
        {:reply, {:error, :record_unreadable}, state}

      true ->
        merge_metadata_into(uuid, metadata, state)
    end
  end

  def handle_call({:delete, uuid}, _from, state) do
    if unreadable?(state, uuid) do
      {:reply, {:error, :record_unreadable}, state}
    else
      {:reply, do_delete(uuid), state}
    end
  end

  def handle_call({:delete_if_match, uuid, generation}, _from, state) do
    reply =
      cond do
        unreadable?(state, uuid) ->
          {:error, :record_unreadable}

        true ->
          case lookup(uuid) do
            # Delete-of-absent is success: a delete retried after a crash must
            # not look like a conflict.
            nil -> :ok
            %Record{generation: ^generation} -> do_delete(uuid)
            %Record{} -> {:error, :conflict}
          end
      end

    {:reply, reply, state}
  end

  def handle_call(:unreadable, _from, state) do
    {:reply, state.unreadable, state}
  end

  def handle_call(:reload, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | unreadable: load_from_disk()}}
  end

  ## Internals

  defp merge_metadata_into(uuid, metadata, state) do
    case lookup(uuid) do
      nil ->
        {:reply, :not_found, state}

      existing ->
        merged = %{existing | metadata: Map.merge(existing.metadata, metadata)}

        case do_put(succeed(merged)) do
          {:ok, stored} ->
            {:reply, {:ok, stored}, state}

          {:error, reason} = err ->
            Logger.error("StateStore merge_metadata failed for #{uuid}: #{inspect(reason)}")
            {:reply, err, state}
        end
    end
  end

  defp lookup(uuid) do
    case :ets.lookup(@table, uuid) do
      [{^uuid, record}] -> record
      [] -> nil
    end
  end

  # Assign the record's place in the sequence: previous generation + 1, or 1 for
  # a record we have not seen. Callers never set this — see moduledoc.
  #
  # Metadata is carried forward when the incoming record has none, so a caller
  # that rebuilds a record from live VM state (`build_running_record/1`) does
  # not silently erase labels an orchestrator set out of band.
  defp succeed(%Record{uuid: uuid} = record) do
    case lookup(uuid) do
      nil ->
        %{record | generation: 1}

      %Record{} = previous ->
        metadata = if map_size(record.metadata) == 0, do: previous.metadata, else: record.metadata
        %{record | generation: previous.generation + 1, metadata: metadata}
    end
  end

  defp do_put(%Record{uuid: uuid} = record) do
    case write_atomic(record) do
      :ok ->
        :ets.insert(@table, {uuid, record})
        {:ok, record}

      {:error, _} = err ->
        err
    end
  end

  defp do_delete(uuid) do
    reply =
      case File.rm(record_path(uuid)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _} = err -> err
      end

    :ets.delete(@table, uuid)
    reply
  end

  defp ensure_dirs do
    with :ok <- File.mkdir_p(state_dir()),
         :ok <- File.mkdir_p(quarantine_dir()) do
      :ok
    end
  end

  defp state_path, do: state_dir()
  defp quarantine_dir, do: Path.join(state_path(), "quarantine")
  defp record_path(uuid), do: Path.join(state_path(), uuid <> ".json")
  defp tmp_path(uuid), do: Path.join(state_path(), uuid <> ".json.tmp")

  defp write_atomic(%Record{uuid: uuid} = record) do
    json = Record.to_json(record)
    tmp = tmp_path(uuid)
    final = record_path(uuid)

    with {:ok, io} <- :file.open(tmp, [:raw, :write, :binary]),
         :ok <- :file.write(io, json),
         :ok <- :file.sync(io),
         :ok <- :file.close(io),
         :ok <- File.rename(tmp, final) do
      :ok
    else
      error ->
        _ = File.rm(tmp)
        {:error, error}
    end
  end

  defp unreadable?(%{unreadable: map}, uuid), do: Map.has_key?(map, uuid)
  defp unreadable?(_state, _uuid), do: false

  # Returns %{uuid => reason} for files left in place because this binary does
  # not speak their schema version.
  # Prefer the key that is actually loaded. A legacy UUID resolves to the
  # base58 record written by `Mjolnir.VmId.Migrate` without renaming a
  # caller that stored some other string under that exact key.
  defp resident_key(id) when is_binary(id) do
    alt = Mjolnir.VmId.storage_id(id)

    cond do
      :ets.member(@table, id) -> id
      alt != id and :ets.member(@table, alt) -> alt
      true -> id
    end
  end

  defp load_from_disk do
    Mjolnir.VmId.Migrate.run()

    case File.ls(state_path()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reduce(%{}, fn filename, acc ->
          case load_one(filename) do
            :ok -> acc
            {:unreadable, uuid, reason} -> Map.put(acc, uuid, reason)
          end
        end)

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.error("StateStore could not list #{state_path()}: #{inspect(reason)}")
        %{}
    end
  end

  defp load_one(filename) do
    path = Path.join(state_path(), filename)

    with {:ok, bin} <- File.read(path),
         {:ok, record} <- Record.from_json(bin) do
      :ets.insert(@table, {record.uuid, record})
      :ok
    else
      # A record from a version we do not speak. The file is intact — the binary
      # that wrote it can still read it — so leave it exactly where it is and
      # hold the UUID back from writes. Quarantining here would rename the file
      # and turn a rollback into permanent data loss.
      {:error, {:unsupported_schema_version, version} = reason} ->
        uuid = Path.basename(filename, ".json")

        Logger.error(
          "StateStore: #{path} was written by schema version #{version}, which this build " <>
            "does not support. Leaving it untouched and refusing writes to #{uuid}. " <>
            "This is the signature of a rollback — roll forward to recover."
        )

        {:unreadable, uuid, reason}

      {:error, reason} ->
        quarantine(path, reason)
        :ok
    end
  end

  defp quarantine(path, reason) do
    ts = DateTime.utc_now() |> DateTime.to_unix()
    name = Path.basename(path)
    dest = Path.join(quarantine_dir(), "#{name}.bad-#{ts}")

    case File.rename(path, dest) do
      :ok ->
        Logger.warning("StateStore quarantined #{path} → #{dest} (#{inspect(reason)})")

      {:error, err} ->
        Logger.error("StateStore failed to quarantine #{path}: #{inspect(err)}")
    end
  end
end
