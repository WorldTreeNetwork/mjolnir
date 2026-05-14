defmodule Mjolnir.Sites.HeadIndex do
  @moduledoc """
  Postgres-backed index over `Mjolnir.Sites.HeadRecord` envelopes.

  The signed envelope itself lives in `Mjolnir.SecretStore` on the
  filesystem — that's the source of truth. This index holds the parsed
  `(identikey_fp, site_name, snapshot_hash, sequence, updated_at)` tuple so
  the serve path can answer "what is the current HEAD for this site?" with
  one SQL query instead of an FS read + JSON parse on every request.

  When `pg_enabled` is false, all operations are no-ops on writes and
  `{:error, :not_indexed}` on reads, so callers can transparently fall back
  to the SecretStore.
  """

  use Ecto.Schema
  import Ecto.Query
  require Logger

  alias Mjolnir.Repo
  alias Mjolnir.Sites.HeadRecord

  @primary_key false
  @schema_prefix "sites"
  schema "head_index" do
    field(:identikey_fp, :string, primary_key: true)
    field(:site_name, :string, primary_key: true)
    field(:snapshot_hash, :string)
    field(:sequence, :integer)
    field(:updated_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          identikey_fp: String.t(),
          site_name: String.t(),
          snapshot_hash: String.t(),
          sequence: integer(),
          updated_at: DateTime.t()
        }

  @doc """
  Upsert the index row from a parsed `HeadRecord`. The record's sequence is
  monotonically enforced at the SQL level — an out-of-order replication
  delivery cannot regress the index.
  """
  @spec upsert(HeadRecord.t()) :: :ok | {:error, term()}
  def upsert(%HeadRecord{} = record) do
    if enabled?() do
      now = DateTime.utc_now()

      entry = %{
        identikey_fp: record.identikey_fp,
        site_name: record.site_name,
        snapshot_hash: record.snapshot_hash,
        sequence: record.sequence,
        updated_at: now
      }

      conflict_target = [:identikey_fp, :site_name]

      # Only overwrite when the incoming sequence is strictly greater. This
      # mirrors HeadRecord.replaces?/2's monotonicity rule.
      on_conflict =
        from(h in __MODULE__,
          where: fragment("EXCLUDED.sequence > ?", h.sequence),
          update: [
            set: [
              snapshot_hash: fragment("EXCLUDED.snapshot_hash"),
              sequence: fragment("EXCLUDED.sequence"),
              updated_at: fragment("EXCLUDED.updated_at")
            ]
          ]
        )

      try do
        {_count, _} =
          Repo.insert_all(__MODULE__, [entry],
            on_conflict: on_conflict,
            conflict_target: conflict_target
          )

        :ok
      rescue
        e ->
          Logger.error("HeadIndex.upsert failed: #{inspect(e)}")
          {:error, e}
      end
    else
      :ok
    end
  end

  @doc """
  Look up the current HEAD pointer for a site. Returns the index row when
  found, `:not_found` when the index has no entry, or `{:error, :not_indexed}`
  when Postgres is disabled (caller should fall back to SecretStore).
  """
  @spec get(String.t(), String.t()) :: {:ok, t()} | :not_found | {:error, :not_indexed}
  def get(identikey_fp, site_name) when is_binary(identikey_fp) and is_binary(site_name) do
    if enabled?() do
      case Repo.get_by(__MODULE__, identikey_fp: identikey_fp, site_name: site_name) do
        nil -> :not_found
        row -> {:ok, row}
      end
    else
      {:error, :not_indexed}
    end
  end

  @doc "List all index rows for one IdentiKey. Useful for snapshot listing."
  @spec list_by_fp(String.t()) :: [t()]
  def list_by_fp(identikey_fp) when is_binary(identikey_fp) do
    if enabled?() do
      Repo.all(from(h in __MODULE__, where: h.identikey_fp == ^identikey_fp))
    else
      []
    end
  end

  defp enabled?, do: Application.get_env(:mjolnir, :pg_enabled, false)
end
