defmodule Mjolnir.Sites.ManifestIndex do
  @moduledoc """
  Postgres-backed index over `Mjolnir.Sites.Manifest` envelopes. The
  serialized envelope bytes stay on disk in `Mjolnir.Sites.Store`; this
  index records the parsed (snapshot_hash, identikey_fp, site_name, mode,
  entry_count, created_at) tuple so administrative queries
  ("list snapshots for site X", "what mode is snapshot Y?") don't have to
  page through manifest envelopes on disk.

  When `pg_enabled` is false, writes are no-ops and reads return
  `{:error, :not_indexed}` so callers can fall back to FS lookups.
  """

  use Ecto.Schema
  import Ecto.Query
  require Logger

  alias Mjolnir.Repo
  alias Mjolnir.Sites.Manifest

  @primary_key {:snapshot_hash, :string, autogenerate: false}
  @schema_prefix "sites"
  schema "manifest_index" do
    field(:identikey_fp, :string)
    field(:site_name, :string)
    field(:mode, :string)
    field(:entry_count, :integer)
    field(:created_at, :utc_datetime_usec)
    field(:indexed_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          snapshot_hash: String.t(),
          identikey_fp: String.t(),
          site_name: String.t(),
          mode: String.t(),
          entry_count: integer(),
          created_at: DateTime.t(),
          indexed_at: DateTime.t()
        }

  @doc """
  Upsert the index row for a parsed manifest. `snapshot_hash` is the SHA over
  the serialized envelope (see `Manifest.snapshot_hash/1`); the caller passes
  it in so we don't recompute it on the hot path. Idempotent — re-indexing
  the same manifest is a no-op apart from `indexed_at` being refreshed.
  """
  @spec upsert(String.t(), Manifest.t()) :: :ok | {:error, term()}
  def upsert(snapshot_hash, %Manifest{} = manifest) when is_binary(snapshot_hash) do
    if enabled?() do
      now = DateTime.utc_now()

      entry = %{
        snapshot_hash: snapshot_hash,
        identikey_fp: manifest.identikey_fp,
        site_name: manifest.site_name,
        mode: Atom.to_string(manifest.mode),
        entry_count: length(manifest.entries),
        created_at: manifest.created_at,
        indexed_at: now
      }

      try do
        {_count, _} =
          Repo.insert_all(__MODULE__, [entry],
            on_conflict: {:replace, [:indexed_at]},
            conflict_target: [:snapshot_hash]
          )

        :ok
      rescue
        e ->
          Logger.error("ManifestIndex.upsert failed: #{inspect(e)}")
          {:error, e}
      end
    else
      :ok
    end
  end

  @spec get(String.t()) :: {:ok, t()} | :not_found | {:error, :not_indexed}
  def get(snapshot_hash) when is_binary(snapshot_hash) do
    if enabled?() do
      case Repo.get(__MODULE__, snapshot_hash) do
        nil -> :not_found
        row -> {:ok, row}
      end
    else
      {:error, :not_indexed}
    end
  end

  @doc "List all manifests known for one (identikey_fp, site_name)."
  @spec list_for_site(String.t(), String.t()) :: [t()]
  def list_for_site(identikey_fp, site_name)
      when is_binary(identikey_fp) and is_binary(site_name) do
    if enabled?() do
      Repo.all(
        from(m in __MODULE__,
          where: m.identikey_fp == ^identikey_fp and m.site_name == ^site_name,
          order_by: [desc: m.created_at]
        )
      )
    else
      []
    end
  end

  defp enabled?, do: Application.get_env(:mjolnir, :pg_enabled, false)
end
