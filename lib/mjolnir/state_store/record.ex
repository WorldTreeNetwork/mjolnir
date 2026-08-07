defmodule Mjolnir.StateStore.Record do
  @moduledoc """
  Per-VM durability record. One on-disk JSON file per record, lives at
  `<state_dir>/<uuid>.json`. Source of intent — used by `Mjolnir.Reconcile`
  at boot to decide which VMs to rehydrate.

  See `docs/plans/durability.md` for the broader design.
  """

  use TypedStruct

  @schema_version 2

  # Schema versions this module can still read. A v1 file is upgraded in memory
  # on load (metadata defaults to empty, generation to 1) and rewritten as v2 on
  # its next `StateStore.put/1`. Reading old-but-valid records is emphatically
  # not the "quarantine, don't discard" case — quarantine is for *corrupt* files,
  # and quarantining every VM on a server during a deploy would be an outage.
  @readable_schema_versions [1, 2]

  @type intent :: :running | :dormant | :stopped | :failed

  typedstruct enforce: true do
    field(:uuid, String.t())
    field(:intent, intent())
    field(:created_at, DateTime.t())
    field(:last_boot_at, DateTime.t() | nil, default: nil)
    field(:spawn_config, map(), default: %{})
    field(:identity, map(), default: %{})
    field(:dormant, map() | nil, default: nil)
    field(:runtime, map(), default: %{})

    # Opaque string=>string labels set by whoever created the VM. Mjolnir never
    # interprets these; they exist so an external orchestrator can select and
    # positively identify its own VMs. See `Mjolnir.StateStore` moduledoc.
    field(:metadata, %{String.t() => String.t()}, default: %{})

    # Monotonic per-record counter, incremented by `StateStore.put/1` on every
    # write. The fencing token for compare-and-delete: a caller that read at
    # generation N can prove nothing has changed since. Owned by the store, never
    # by the caller — see the note on `new/3`.
    field(:generation, pos_integer(), default: 1)
  end

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Build a record.

  Note `generation` is deliberately **not** an option. `build_running_record/1`
  and friends construct a fresh record on every persist, so a caller-supplied
  generation would reset to 1 each time and silently destroy the fencing
  guarantee. `StateStore.put/1` assigns it from the record already on disk.
  """
  @spec new(String.t(), intent(), keyword()) :: t()
  def new(uuid, intent, opts \\ []) when intent in [:running, :dormant, :stopped, :failed] do
    %__MODULE__{
      uuid: uuid,
      intent: intent,
      created_at: Keyword.get(opts, :created_at, DateTime.utc_now()),
      last_boot_at: Keyword.get(opts, :last_boot_at),
      spawn_config: Keyword.get(opts, :spawn_config, %{}),
      identity: Keyword.get(opts, :identity, %{}),
      dormant: Keyword.get(opts, :dormant),
      runtime: Keyword.get(opts, :runtime, %{}),
      metadata: opts |> Keyword.get(:metadata, %{}) |> normalize_metadata()
    }
  end

  @doc """
  Coerce a metadata map to `string => string`, dropping anything that cannot be
  represented. Keys and values arrive from JSON request bodies, so this is a
  boundary, not a formality.
  """
  @spec normalize_metadata(term()) :: %{String.t() => String.t()}
  def normalize_metadata(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  def normalize_metadata(_), do: %{}

  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = record) do
    %{
      "schema_version" => @schema_version,
      "uuid" => record.uuid,
      "intent" => Atom.to_string(record.intent),
      "created_at" => DateTime.to_iso8601(record.created_at),
      "last_boot_at" =>
        case record.last_boot_at do
          nil -> nil
          dt -> DateTime.to_iso8601(dt)
        end,
      "spawn_config" => record.spawn_config,
      "identity" => record.identity,
      "dormant" => record.dormant,
      "runtime" => record.runtime,
      "metadata" => record.metadata,
      "generation" => record.generation
    }
    |> Jason.encode!(pretty: true)
  end

  @spec from_json(String.t()) ::
          {:ok, t()}
          | {:error, :invalid_json | :schema_version_mismatch | :missing_field | :invalid_intent}
  def from_json(binary) when is_binary(binary) do
    with {:ok, map} <- Jason.decode(binary) |> normalize_decode(),
         :ok <- check_schema_version(map),
         {:ok, uuid} <- fetch(map, "uuid"),
         {:ok, intent_str} <- fetch(map, "intent"),
         {:ok, intent} <- parse_intent(intent_str),
         {:ok, created_at} <- parse_datetime(Map.get(map, "created_at")),
         {:ok, last_boot_at} <- parse_optional_datetime(Map.get(map, "last_boot_at")) do
      {:ok,
       %__MODULE__{
         uuid: uuid,
         intent: intent,
         created_at: created_at,
         last_boot_at: last_boot_at,
         spawn_config: Map.get(map, "spawn_config") || %{},
         identity: Map.get(map, "identity") || %{},
         dormant: Map.get(map, "dormant"),
         runtime: Map.get(map, "runtime") || %{},
         # Absent on v1 records; the defaults are the upgrade.
         metadata: map |> Map.get("metadata") |> normalize_metadata(),
         generation: parse_generation(Map.get(map, "generation"))
       }}
    end
  end

  # A generation must be a positive integer. Anything else — absent (v1), null,
  # a float, a string, or a negative — reads as 1 rather than failing the load:
  # a record we cannot fence is still a record we must not lose. The first
  # `put/1` then re-establishes a sane counter.
  defp parse_generation(n) when is_integer(n) and n > 0, do: n
  defp parse_generation(_), do: 1

  defp normalize_decode({:ok, map}) when is_map(map), do: {:ok, map}
  defp normalize_decode({:ok, _}), do: {:error, :invalid_json}
  defp normalize_decode({:error, _}), do: {:error, :invalid_json}

  defp check_schema_version(%{"schema_version" => v}) when v in @readable_schema_versions, do: :ok
  defp check_schema_version(_), do: {:error, :schema_version_mismatch}

  defp fetch(map, key) do
    case Map.get(map, key) do
      nil -> {:error, :missing_field}
      v -> {:ok, v}
    end
  end

  defp parse_intent("running"), do: {:ok, :running}
  defp parse_intent("dormant"), do: {:ok, :dormant}
  defp parse_intent("stopped"), do: {:ok, :stopped}
  defp parse_intent("failed"), do: {:ok, :failed}
  defp parse_intent(_), do: {:error, :invalid_intent}

  defp parse_datetime(nil), do: {:error, :missing_field}

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, :missing_field}
    end
  end

  defp parse_optional_datetime(nil), do: {:ok, nil}
  defp parse_optional_datetime(iso), do: parse_datetime(iso)
end
