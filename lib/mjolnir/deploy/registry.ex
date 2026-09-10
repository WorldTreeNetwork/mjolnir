defmodule Mjolnir.Deploy.Registry do
  @moduledoc """
  Durable per-app deployment registry. One JSON file per app under
  `<deploy_state_dir>/registry/<slug>.json`; an in-process ETS table mirrors
  the files for fast reads.

  ## Guarantees

  - **Atomic on-disk writes**: writes go to `<slug>.json.tmp`, are fsynced,
    then renamed over the final path.
  - **Cache coherence**: ETS is updated after the file rename succeeds.
  - **Fault-tolerant init**: unreadable or malformed JSON files are skipped
    (logged as warnings) so a single bad file cannot crash startup.

  ## Isolation

  Each GenServer instance owns a **private** (anonymous) ETS table — no
  globally-named table. This lets tests run `async: true` without clashing.
  """

  use GenServer
  require Logger

  @default_state_dir "/var/lib/mjolnir/deploy/registry"

  defmodule Entry do
    @moduledoc "A single app's current deployment record."

    @type t :: %__MODULE__{
            app_name: String.t(),
            release_snapshot: String.t(),
            service_vm_id: String.t() | nil,
            url: String.t() | nil,
            custom_domain: String.t() | nil,
            port: pos_integer() | nil,
            owner_id: String.t() | nil,
            stateful: boolean(),
            updated_at: integer()
          }

    @enforce_keys [:app_name, :release_snapshot, :updated_at]
    defstruct [
      :app_name,
      :release_snapshot,
      :service_vm_id,
      :url,
      # Custom domain (fqdn, e.g. "zine.identikey.io") this app is served under.
      # Optional; drives gateway local-route generation (Mjolnir.Gateway.Routes).
      :custom_domain,
      # Internal app port inside the VM (e.g. 3000). Optional; the route backend
      # is "#{guest_ip}:#{port}".
      :port,
      # The user_id that deployed this app. Drives Mjolnir.Policy.App, which
      # gates redeploy and domain retargeting (mjolnir-xuv). nil means a legacy
      # entry written before ownership existed: Policy.App denies those to
      # regular users and allows only localhost, matching Policy.VM's treatment
      # of nil-owner VMs. Back-fill rather than relaxing the policy.
      :owner_id,
      :updated_at,
      # Adopted stateful app (B0 hive, etc.). Deploy.Runtime refuses cutover
      # unless `:force`. Default false so existing JSON files stay deployable.
      stateful: false
    ]
  end

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Upsert a deployment entry. Stamps `updated_at` to current unix time."
  @spec put(GenServer.server(), String.t(), map()) :: {:ok, Entry.t()} | {:error, term()}
  def put(server \\ __MODULE__, app_name, attrs) when is_binary(app_name) and is_map(attrs) do
    GenServer.call(server, {:put, app_name, attrs})
  end

  @doc "Look up an entry by app name. Returns `{:ok, entry}` or `{:error, :not_found}`."
  @spec get(GenServer.server(), String.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  def get(server \\ __MODULE__, app_name) when is_binary(app_name) do
    GenServer.call(server, {:get, app_name})
  end

  @doc "All entries, in unspecified order."
  @spec list(GenServer.server()) :: [Entry.t()]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @doc "Remove an entry from disk and cache. Idempotent."
  @spec delete(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def delete(server \\ __MODULE__, app_name) when is_binary(app_name) do
    GenServer.call(server, {:delete, app_name})
  end

  ## GenServer

  @impl true
  def init(opts) do
    dir =
      Keyword.get(
        opts,
        :dir,
        Application.get_env(:mjolnir, :deploy_state_dir, @default_state_dir)
      )

    table = :ets.new(:deploy_registry, [:set, :protected, read_concurrency: true])

    :ok = ensure_dir(dir)
    load_from_disk(dir, table)

    {:ok, %{dir: dir, table: table}}
  end

  @impl true
  def handle_call({:put, app_name, attrs}, _from, %{dir: dir, table: table} = state) do
    entry = build_entry(app_name, attrs)

    case write_atomic(entry, dir) do
      :ok ->
        :ets.insert(table, {app_name, entry})
        {:reply, {:ok, entry}, state}

      {:error, _} = err ->
        Logger.error("Deploy.Registry put failed for #{app_name}: #{inspect(err)}")
        {:reply, err, state}
    end
  end

  def handle_call({:get, app_name}, _from, %{table: table} = state) do
    result =
      case :ets.lookup(table, app_name) do
        [{^app_name, entry}] -> {:ok, entry}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call(:list, _from, %{table: table} = state) do
    entries = table |> :ets.tab2list() |> Enum.map(fn {_k, v} -> v end)
    {:reply, entries, state}
  end

  def handle_call({:delete, app_name}, _from, %{dir: dir, table: table} = state) do
    path = record_path(dir, app_name)

    reply =
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _} = err -> err
      end

    :ets.delete(table, app_name)
    {:reply, reply, state}
  end

  ## Internals

  defp build_entry(app_name, attrs) do
    %Entry{
      app_name: app_name,
      release_snapshot: Map.fetch!(attrs, :release_snapshot),
      service_vm_id: Map.get(attrs, :service_vm_id),
      url: Map.get(attrs, :url),
      custom_domain: Map.get(attrs, :custom_domain),
      port: Map.get(attrs, :port),
      owner_id: Map.get(attrs, :owner_id),
      stateful: Map.get(attrs, :stateful, false) == true,
      updated_at: Map.get(attrs, :updated_at, System.os_time(:second))
    }
  end

  defp ensure_dir(dir) do
    File.mkdir_p(dir)
  end

  defp safe_slug(app_name) do
    app_name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "_")
  end

  defp record_path(dir, app_name), do: Path.join(dir, safe_slug(app_name) <> ".json")
  defp tmp_path(dir, app_name), do: Path.join(dir, safe_slug(app_name) <> ".json.tmp")

  defp write_atomic(%Entry{app_name: app_name} = entry, dir) do
    json = entry_to_json(entry)
    tmp = tmp_path(dir, app_name)
    final = record_path(dir, app_name)

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

  defp entry_to_json(%Entry{} = entry) do
    Jason.encode!(%{
      "app_name" => entry.app_name,
      "release_snapshot" => entry.release_snapshot,
      "service_vm_id" => entry.service_vm_id,
      "url" => entry.url,
      "custom_domain" => entry.custom_domain,
      "port" => entry.port,
      "owner_id" => entry.owner_id,
      "stateful" => entry.stateful,
      "updated_at" => entry.updated_at
    })
  end

  defp entry_from_map(map) do
    with %{"app_name" => app_name, "release_snapshot" => snap, "updated_at" => updated_at}
         when is_binary(app_name) and is_binary(snap) and is_integer(updated_at) <- map do
      {:ok,
       %Entry{
         app_name: app_name,
         release_snapshot: snap,
         service_vm_id: Map.get(map, "service_vm_id"),
         url: Map.get(map, "url"),
         # Backward compatible: old files predate these keys; Map.get → nil.
         custom_domain: Map.get(map, "custom_domain"),
         port: Map.get(map, "port"),
         # nil here means a pre-ownership entry. Policy.App treats that as
         # "localhost only" rather than "anyone", so a legacy file fails closed.
         owner_id: Map.get(map, "owner_id"),
         stateful: Map.get(map, "stateful", false) == true,
         updated_at: updated_at
       }}
    else
      _ -> {:error, :invalid_record}
    end
  end

  defp load_from_disk(dir, table) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.each(&load_one(Path.join(dir, &1), table))

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.error("Deploy.Registry could not list #{dir}: #{inspect(reason)}")
    end
  end

  defp load_one(path, table) do
    with {:ok, bin} <- File.read(path),
         {:ok, map} <- Jason.decode(bin),
         {:ok, entry} <- entry_from_map(map) do
      :ets.insert(table, {entry.app_name, entry})
    else
      {:error, reason} ->
        Logger.warning("Deploy.Registry skipping #{path}: #{inspect(reason)}")
    end
  end
end
