defmodule Mjolnir.Forge.AuditLog do
  @moduledoc """
  Append-only audit log of Forge events, one JSON object per line (JSONL),
  at `<forge_state_dir>/_events/audit.jsonl`.

  This GenServer is the single serialization point for event ids: every event
  flows through `append/1`, which stamps a strictly-monotonic `id`
  (`max(os_time_µs, last_id + 1)`). That `id` doubles as the SSE resume cursor
  — `?since=<id>` replays everything after it.

  ## Durability

  Best-effort, like the Postgres derived indexes: we append + flush but do not
  `fsync` every line, so a hard crash may lose the last few events. The audit
  log is observability, not the source of truth (the `Forge.Store` records and
  on-disk declarations are). Rotation is a future concern — see the v1+ notes
  on the `mjolnir-70e` issue.

  ## Path resolution

  The directory is resolved on every call from `Forge.Store.state_dir/0`, so
  overriding `:forge_state_dir` at runtime (as the test suite does) takes
  effect without a restart. The `_events` directory name is reserved and
  skipped by `Forge.Store` when it scans host directories.
  """

  use GenServer
  require Logger

  alias Mjolnir.Forge.{Events, Store}

  @dir_name "_events"
  @file_name "audit.jsonl"

  ## Public API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Append an event. Stamps a monotonic `id`, writes one JSON line, and returns
  the stamped event so the caller can publish it with the same `id`.
  """
  @spec append(Events.Event.t()) :: Events.Event.t()
  def append(%Events.Event{} = event), do: GenServer.call(__MODULE__, {:append, event})

  @doc "Events with `id` strictly greater than `cursor`, in append order."
  @spec since(integer()) :: [Events.Event.t()]
  def since(cursor) when is_integer(cursor) do
    read_all() |> Enum.filter(&(&1.id > cursor))
  end

  @doc "The most recent `limit` events, in append order."
  @spec recent(pos_integer()) :: [Events.Event.t()]
  def recent(limit) when is_integer(limit) and limit > 0 do
    read_all() |> Enum.take(-limit)
  end

  @doc "Absolute path to the audit log file under the current state dir."
  @spec path() :: String.t()
  def path, do: Path.join([Store.state_dir(), @dir_name, @file_name])

  ## GenServer

  @impl true
  def init(_opts) do
    # last_id seeds from the file so ids stay monotonic across restarts.
    last_id =
      read_all()
      |> List.last()
      |> case do
        nil -> 0
        ev -> ev.id
      end

    {:ok, %{last_id: last_id}}
  end

  @impl true
  def handle_call({:append, event}, _from, %{last_id: last} = state) do
    id = max(System.os_time(:microsecond), last + 1)
    stamped = %{event | id: id}

    case write_line(stamped) do
      :ok ->
        {:reply, stamped, %{state | last_id: id}}

      {:error, reason} ->
        Logger.error("Forge.AuditLog append failed: #{inspect(reason)}")
        # Still return the stamped event — publish should proceed even if the
        # durable write failed; live subscribers shouldn't be starved by a
        # disk hiccup.
        {:reply, stamped, %{state | last_id: id}}
    end
  end

  ## Internals

  defp write_line(event) do
    line = [Jason.encode!(Events.to_json(event)), ?\n]
    dir = Path.dirname(path())

    with :ok <- File.mkdir_p(dir),
         {:ok, io} <- :file.open(path(), [:append, :raw, :binary]),
         :ok <- :file.write(io, line) do
      :file.close(io)
      :ok
    else
      {:error, _} = err -> err
    end
  end

  defp read_all do
    case File.read(path()) do
      {:ok, bin} ->
        bin
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_line/1)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.error("Forge.AuditLog read failed: #{inspect(reason)}")
        []
    end
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, map} -> [Events.from_json(map)]
      {:error, _} -> []
    end
  end
end
