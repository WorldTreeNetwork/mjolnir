defmodule Mjolnir.Forge.Store.Record do
  @moduledoc """
  Per-resource ownership + status record. One on-disk JSON file lives at
  `<forge_state_dir>/<host>/<safe_key>.json`. Identity is `(host, kind, id)`.

  Mirrors `Mjolnir.StateStore.Record` in shape and persistence semantics
  (atomic writes, schema versioning, quarantine on bad data).
  """

  use TypedStruct

  @schema_version 1

  @type status ::
          :converged
          | :drifted
          | :missing
          | :new
          | :conflict
          | :prune
          | :tombstone
          | :unmanaged
          | :ignored

  typedstruct enforce: true do
    field :host, String.t()
    field :kind, String.t()
    field :resource_id, String.t()
    field :status, status()
    field :declared_hash, binary() | nil, default: nil
    field :owned_hash, binary() | nil, default: nil
    field :observed_hash, binary() | nil, default: nil
    field :applied_at, DateTime.t() | nil, default: nil
    field :observed_at, DateTime.t() | nil, default: nil
    field :inserted_at, DateTime.t()
    field :updated_at, DateTime.t()
  end

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec new(String.t(), String.t(), String.t(), keyword()) :: t()
  def new(host, kind, resource_id, opts \\ []) do
    now = DateTime.utc_now()

    %__MODULE__{
      host: host,
      kind: kind,
      resource_id: resource_id,
      status: Keyword.get(opts, :status, :new),
      declared_hash: Keyword.get(opts, :declared_hash),
      owned_hash: Keyword.get(opts, :owned_hash),
      observed_hash: Keyword.get(opts, :observed_hash),
      applied_at: Keyword.get(opts, :applied_at),
      observed_at: Keyword.get(opts, :observed_at),
      inserted_at: Keyword.get(opts, :inserted_at, now),
      updated_at: Keyword.get(opts, :updated_at, now)
    }
  end

  @spec key(t()) :: {String.t(), String.t(), String.t()}
  def key(%__MODULE__{host: h, kind: k, resource_id: id}), do: {h, k, id}

  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = r) do
    %{
      "schema_version" => @schema_version,
      "host" => r.host,
      "kind" => r.kind,
      "resource_id" => r.resource_id,
      "status" => Atom.to_string(r.status),
      "declared_hash" => encode_hash(r.declared_hash),
      "owned_hash" => encode_hash(r.owned_hash),
      "observed_hash" => encode_hash(r.observed_hash),
      "applied_at" => encode_dt(r.applied_at),
      "observed_at" => encode_dt(r.observed_at),
      "inserted_at" => DateTime.to_iso8601(r.inserted_at),
      "updated_at" => DateTime.to_iso8601(r.updated_at)
    }
    |> Jason.encode!(pretty: true)
  end

  @spec from_json(String.t()) ::
          {:ok, t()}
          | {:error, :invalid_json | :schema_version_mismatch | :missing_field | :invalid_status}
  def from_json(bin) when is_binary(bin) do
    with {:ok, map} <- decode(bin),
         :ok <- check_schema(map),
         {:ok, host} <- fetch(map, "host"),
         {:ok, kind} <- fetch(map, "kind"),
         {:ok, rid} <- fetch(map, "resource_id"),
         {:ok, status_s} <- fetch(map, "status"),
         {:ok, status} <- parse_status(status_s),
         {:ok, inserted_at} <- parse_dt(Map.get(map, "inserted_at")),
         {:ok, updated_at} <- parse_dt(Map.get(map, "updated_at")) do
      {:ok,
       %__MODULE__{
         host: host,
         kind: kind,
         resource_id: rid,
         status: status,
         declared_hash: decode_hash(Map.get(map, "declared_hash")),
         owned_hash: decode_hash(Map.get(map, "owned_hash")),
         observed_hash: decode_hash(Map.get(map, "observed_hash")),
         applied_at: parse_dt_opt(Map.get(map, "applied_at")),
         observed_at: parse_dt_opt(Map.get(map, "observed_at")),
         inserted_at: inserted_at,
         updated_at: updated_at
       }}
    end
  end

  defp decode(bin) do
    case Jason.decode(bin) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_json}
    end
  end

  defp check_schema(%{"schema_version" => v}) when v == @schema_version, do: :ok
  defp check_schema(_), do: {:error, :schema_version_mismatch}

  defp fetch(map, key) do
    case Map.get(map, key) do
      nil -> {:error, :missing_field}
      v -> {:ok, v}
    end
  end

  defp parse_status(s) when s in ~w(converged drifted missing new conflict prune tombstone unmanaged ignored),
    do: {:ok, String.to_existing_atom(s)}

  defp parse_status(_), do: {:error, :invalid_status}

  defp parse_dt(nil), do: {:error, :missing_field}

  defp parse_dt(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, :missing_field}
    end
  end

  defp parse_dt_opt(nil), do: nil

  defp parse_dt_opt(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp encode_dt(nil), do: nil
  defp encode_dt(dt), do: DateTime.to_iso8601(dt)

  defp encode_hash(nil), do: nil
  defp encode_hash(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)

  defp decode_hash(nil), do: nil

  defp decode_hash(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} -> bin
      :error -> nil
    end
  end
end
