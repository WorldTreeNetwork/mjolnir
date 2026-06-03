defmodule Mjolnir.Forge.Events do
  @moduledoc """
  Forge reconciliation events: the struct, the `emit/1` front door, JSON/SSE
  serialization, and convenience builders used by `Forge.Host`.

  ## Event types

    * `:probe`  — a host was observed/diffed; `detail.counts` summarizes
      statuses found this pass
    * `:drift`  — a single resource is out of sync (status `:new`, `:drifted`,
      `:missing`, `:prune`, `:conflict`, or `:unmanaged`)
    * `:apply`  — outcome of applying one resource (`detail.result` is
      `"ok"` / `"error"`)
    * `:adopt`  — a converged-but-unowned resource was taken under management
    * `:ignore` — an unmanaged resource was marked ignored

  ## Emission flow

  `emit/1` appends to `Forge.AuditLog` (which stamps the monotonic `id`) and
  then publishes the stamped event through `Forge.EventBus`. Audit-first means
  the durable cursor is assigned before any subscriber sees the event, so a
  reconnecting client can always resume from where it left off.

  > Note: `:ignore` events have a builder here but no caller yet — the
  > adopt/ignore HTTP endpoints land with the TUI ticket (`mjolnir-5ma`).
  > Wiring the trigger is a one-liner there.
  """

  alias Mjolnir.Forge.{AuditLog, EventBus}

  @drift_statuses [:new, :drifted, :missing, :prune, :conflict, :unmanaged]

  defmodule Event do
    @moduledoc "A single Forge event. `id` is the monotonic SSE resume cursor."
    use TypedStruct

    @type type :: :probe | :drift | :apply | :adopt | :ignore

    typedstruct do
      field(:id, integer() | nil, default: nil)
      field(:ts, DateTime.t(), enforce: true)
      field(:host, String.t(), enforce: true)
      field(:type, type(), enforce: true)
      field(:kind, String.t() | nil, default: nil)
      field(:resource_id, String.t() | nil, default: nil)
      field(:status, String.t() | nil, default: nil)
      field(:detail, map(), default: %{})
    end
  end

  @doc "Statuses considered drift (worth a `:drift` event)."
  @spec drift_statuses() :: [atom()]
  def drift_statuses, do: @drift_statuses

  @doc """
  Build (but don't emit) an event from a keyword/map of attributes. Stamps
  `ts`; leaves `id` nil until `AuditLog.append/1` assigns it.
  """
  @spec new(map() | keyword()) :: Event.t()
  def new(attrs) do
    attrs = Map.new(attrs)

    %Event{
      ts: DateTime.utc_now(),
      host: Map.fetch!(attrs, :host),
      type: Map.fetch!(attrs, :type),
      kind: Map.get(attrs, :kind),
      resource_id: Map.get(attrs, :resource_id),
      status: Map.get(attrs, :status),
      detail: Map.get(attrs, :detail, %{})
    }
  end

  @doc """
  Build, persist, and publish an event. Returns the stamped event (with `id`).
  """
  @spec emit(map() | keyword()) :: Event.t()
  def emit(attrs) do
    stamped = attrs |> new() |> AuditLog.append()
    :ok = EventBus.publish(stamped)
    stamped
  end

  ## Host-facing builders

  @doc "Emit one `:probe` summary for a plan pass over `host`."
  @spec probe(String.t(), [map()]) :: Event.t()
  def probe(host, entries) do
    counts =
      entries
      |> Enum.frequencies_by(& &1.status)
      |> Map.new(fn {status, n} -> {Atom.to_string(status), n} end)

    emit(host: host, type: :probe, detail: %{counts: counts, total: length(entries)})
  end

  @doc "Emit a `:drift` event for each non-converged entry. Returns the emitted events."
  @spec drift(String.t(), [map()]) :: [Event.t()]
  def drift(host, entries) do
    for entry <- entries, entry.status in @drift_statuses do
      emit(
        host: host,
        type: :drift,
        kind: kind_string(entry.kind),
        resource_id: entry.id,
        status: Atom.to_string(entry.status)
      )
    end
  end

  @doc """
  Emit the outcome of applying one entry. An adopt-in-place (`:converged`
  entry) is recorded as type `:adopt`; everything else as `:apply`.
  """
  @spec apply_outcome(String.t(), map(), :ok | {:error, term()}) :: Event.t()
  def apply_outcome(host, entry, result) do
    type = if entry.status == :converged, do: :adopt, else: :apply

    detail =
      case result do
        :ok -> %{result: "ok"}
        {:error, reason} -> %{result: "error", reason: inspect(reason)}
      end

    emit(
      host: host,
      type: type,
      kind: kind_string(entry.kind),
      resource_id: entry.id,
      status: Atom.to_string(entry.status),
      detail: detail
    )
  end

  ## Serialization

  @doc "JSON-friendly map with string keys."
  @spec to_json(Event.t()) :: map()
  def to_json(%Event{} = e) do
    %{
      "id" => e.id,
      "ts" => DateTime.to_iso8601(e.ts),
      "host" => e.host,
      "type" => Atom.to_string(e.type),
      "kind" => e.kind,
      "resource_id" => e.resource_id,
      "status" => e.status,
      "detail" => e.detail
    }
  end

  @doc "Reconstruct an event from a decoded JSON map (audit-log replay)."
  @spec from_json(map()) :: Event.t()
  def from_json(map) do
    %Event{
      id: map["id"],
      ts: parse_dt(map["ts"]),
      host: map["host"],
      type: String.to_existing_atom(map["type"]),
      kind: map["kind"],
      resource_id: map["resource_id"],
      status: map["status"],
      detail: map["detail"] || %{}
    }
  end

  @doc """
  Render an event as an SSE frame: `id:` (resume cursor), `event:` (type),
  `data:` (JSON), terminated by a blank line.
  """
  @spec to_sse(Event.t()) :: binary()
  def to_sse(%Event{} = e) do
    json = Jason.encode!(to_json(e))

    """
    id: #{e.id}
    event: #{e.type}
    data: #{json}

    """
  end

  ## Helpers

  # Resource `kind` arrives as the implementation module; store the short
  # string form ("systemd_unit") that the rest of the API speaks.
  defp kind_string(kind) when is_atom(kind), do: kind.kind()
  defp kind_string(kind) when is_binary(kind), do: kind

  defp parse_dt(nil), do: DateTime.utc_now()

  defp parse_dt(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> DateTime.utc_now()
    end
  end
end
