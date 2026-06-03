defmodule Mjolnir.Forge.Store do
  @moduledoc """
  Durable per-resource ownership + status store. Mirrors `Mjolnir.StateStore`:
  one JSON file per `(host, kind, resource_id)` triple under
  `<forge_state_dir>/<host>/<safe_key>.json`, with an ETS cache for reads.

  Identity: `{host, kind, resource_id}`. Status transitions live in
  `Forge.Diff`; this module is just storage.

  ## Guarantees

  - Atomic on-disk writes via `.tmp` + rename + fsync (same path as
    `StateStore.write_atomic/1`).
  - ETS is updated only after the file rename succeeds; failed disk writes
    are not reflected in the cache.
  - Bad files are moved to `<forge_state_dir>/<host>/quarantine/` and logged,
    never silently deleted.
  - Reads are lock-free ETS lookups. Writes serialize through the GenServer.
  """

  use GenServer
  require Logger

  alias Mjolnir.Forge.Store.Record

  @table __MODULE__

  ## Public API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Look up a single record by (host, kind, resource_id)."
  @spec get(String.t(), String.t(), String.t()) :: {:ok, Record.t()} | :not_found
  def get(host, kind, id) do
    case :ets.lookup(@table, {host, kind, id}) do
      [{_, record}] -> {:ok, record}
      [] -> :not_found
    end
  end

  @doc "All records for a host, in unspecified order."
  @spec list_host(String.t()) :: [Record.t()]
  def list_host(host) do
    :ets.tab2list(@table)
    |> Enum.flat_map(fn
      {{^host, _kind, _id}, record} -> [record]
      _ -> []
    end)
  end

  @doc "Resources where `owned_hash` is set — i.e. ones we've previously applied."
  @spec list_owned(String.t()) :: [Record.t()]
  def list_owned(host) do
    list_host(host) |> Enum.filter(&(&1.owned_hash != nil))
  end

  @doc "Map of `{kind, id} => owned_hash` for diff input."
  @spec owned_map(String.t()) :: %{{module(), String.t()} => binary()}
  def owned_map(host) do
    for record <- list_owned(host),
        mod = kind_to_module(record.kind),
        do: {{mod, record.resource_id}, record.owned_hash},
        into: %{}
  end

  @doc "All records across all hosts."
  @spec list() :: [Record.t()]
  def list, do: :ets.tab2list(@table) |> Enum.map(fn {_, r} -> r end)

  @doc """
  Persist a record. Atomic write to disk, then ETS upsert. Bumps `updated_at`.
  """
  @spec put(Record.t()) :: :ok | {:error, term()}
  def put(%Record{} = record), do: GenServer.call(__MODULE__, {:put, record})

  @doc "Remove a record from disk and cache. Idempotent."
  @spec delete(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(host, kind, id), do: GenServer.call(__MODULE__, {:delete, host, kind, id})

  @doc "Reload the cache from disk."
  @spec reload() :: :ok
  def reload, do: GenServer.call(__MODULE__, :reload)

  @doc "Configured root directory (`config :mjolnir, :forge_state_dir`)."
  @spec state_dir() :: String.t()
  def state_dir, do: Application.fetch_env!(:mjolnir, :forge_state_dir)

  ## GenServer

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    :ok = ensure_dir(state_dir())
    :ok = load_from_disk()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, %Record{} = record}, _from, state) do
    record = %{record | updated_at: DateTime.utc_now()}

    case write_atomic(record) do
      :ok ->
        :ets.insert(@table, {Record.key(record), record})
        {:reply, :ok, state}

      {:error, reason} = err ->
        Logger.error(
          "Forge.Store put failed for #{inspect(Record.key(record))}: #{inspect(reason)}"
        )

        {:reply, err, state}
    end
  end

  def handle_call({:delete, host, kind, id}, _from, state) do
    path = record_path(host, kind, id)

    reply =
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _} = err -> err
      end

    :ets.delete(@table, {host, kind, id})
    {:reply, reply, state}
  end

  def handle_call(:reload, _from, state) do
    :ets.delete_all_objects(@table)
    :ok = load_from_disk()
    {:reply, :ok, state}
  end

  ## Internals

  defp ensure_dir(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.mkdir_p(Path.join(dir, "_quarantine")) do
      :ok
    end
  end

  defp host_dir(host), do: Path.join(state_dir(), safe(host))
  defp quarantine_dir(host), do: Path.join(host_dir(host), "_quarantine")

  defp record_path(host, kind, id) do
    Path.join(host_dir(host), safe("#{kind}__#{id}") <> ".json")
  end

  defp tmp_path(host, kind, id), do: record_path(host, kind, id) <> ".tmp"

  # Filesystem-safe encoding. Resource IDs can contain `/` (drop-ins like
  # `unit.d/override.conf`) and `:`, so we replace anything that isn't an
  # alnum/dash/dot/underscore with `_<hex>`.
  defp safe(s) do
    s
    |> :unicode.characters_to_binary()
    |> :binary.bin_to_list()
    |> Enum.map_join(fn
      c when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9) ->
        <<c>>

      c when c in [?-, ?., ?_] ->
        <<c>>

      c ->
        "_" <> Base.encode16(<<c>>, case: :lower)
    end)
  end

  defp write_atomic(%Record{host: host, kind: kind, resource_id: id} = record) do
    :ok = ensure_dir(host_dir(host))
    json = Record.to_json(record)
    tmp = tmp_path(host, kind, id)
    final = record_path(host, kind, id)

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

  defp load_from_disk do
    case File.ls(state_dir()) do
      {:ok, host_dirs} ->
        host_dirs
        |> Enum.each(&load_host_dir/1)

        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.error("Forge.Store could not list #{state_dir()}: #{inspect(reason)}")
        :ok
    end
  end

  defp load_host_dir("_quarantine"), do: :ok
  # Reserved for Forge.AuditLog's JSONL event log — not a host record dir.
  defp load_host_dir("_events"), do: :ok

  defp load_host_dir(host_dir_name) do
    dir = Path.join(state_dir(), host_dir_name)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.each(&load_one(Path.join(dir, &1)))

      _ ->
        :ok
    end
  end

  defp load_one(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, record} <- Record.from_json(bin) do
      :ets.insert(@table, {Record.key(record), record})
      :ok
    else
      {:error, reason} -> quarantine(path, reason)
    end
  end

  defp quarantine(path, reason) do
    ts = DateTime.utc_now() |> DateTime.to_unix()
    base = Path.basename(path)
    host = path |> Path.dirname() |> Path.basename()
    dest = Path.join(quarantine_dir(host), "#{base}.bad-#{ts}")
    File.mkdir_p(quarantine_dir(host))

    case File.rename(path, dest) do
      :ok ->
        Logger.warning("Forge.Store quarantined #{path} → #{dest} (#{inspect(reason)})")

      {:error, err} ->
        Logger.error("Forge.Store failed to quarantine #{path}: #{inspect(err)}")
    end
  end

  # Map a stored kind string back to its implementation module. Extending
  # this is how new resource kinds register themselves to be loadable from
  # the on-disk store after a restart.
  @kind_modules %{
    "systemd_unit" => Mjolnir.Forge.Resource.SystemdUnit,
    "file" => Mjolnir.Forge.Resource.File
  }

  @spec kind_to_module(String.t()) :: module() | nil
  def kind_to_module(kind), do: Map.get(@kind_modules, kind)
end
