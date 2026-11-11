defmodule Mjolnir.AIE.Pending do
  @moduledoc """
  In-memory pending-admit table (ADR 0015 Decision 4).

  Enqueue consumes a nonce, stores the verified frame, and returns
  `pending_id`. Admission names that id plus occupancy `attempt_id`.
  Restart of this process invalidates every id. `dispatched` is
  historical status, not load authority.
  """

  use GenServer

  @required_frame [
    "biscuit_digest",
    "audience",
    "resource",
    "design_id",
    "input_blake3",
    "idempotency_key",
    "holder_fp"
  ]

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec enqueue(GenServer.server(), String.t(), map()) ::
          {:ok, String.t()} | {:error, atom()}
  def enqueue(server \\ __MODULE__, nonce, frame)
      when is_binary(nonce) and is_map(frame) do
    GenServer.call(server, {:enqueue, nonce, frame})
  end

  @spec admit(GenServer.server(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, atom()}
  def admit(server \\ __MODULE__, pending_id, attempt_id, presented)
      when is_binary(pending_id) and is_binary(attempt_id) and is_map(presented) do
    GenServer.call(server, {:admit, pending_id, attempt_id, presented})
  end

  @spec cancel(GenServer.server(), String.t()) :: :ok | {:error, atom()}
  def cancel(server \\ __MODULE__, pending_id) when is_binary(pending_id) do
    GenServer.call(server, {:cancel, pending_id})
  end

  @spec fetch(GenServer.server(), String.t()) :: {:ok, map()} | {:error, :unknown}
  def fetch(server \\ __MODULE__, pending_id) when is_binary(pending_id) do
    GenServer.call(server, {:fetch, pending_id})
  end

  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @spec job_digest(map()) :: String.t()
  def job_digest(frame) when is_map(frame) do
    payload =
      Jason.encode!(%{
        "design_id" => frame["design_id"] || frame[:design_id],
        "input_blake3" => frame["input_blake3"] || frame[:input_blake3],
        "resource" => frame["resource"] || frame[:resource]
      })

    Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
  end

  @spec valid_frame?(map()) :: boolean()
  def valid_frame?(frame) when is_map(frame) do
    keys = stringify_keys(frame)

    Enum.all?(@required_frame, fn key ->
      case keys[key] do
        value when is_binary(value) and value != "" -> true
        _ -> false
      end
    end)
  end

  @impl true
  def init(opts) do
    {:ok, %{rows: %{}, max_age_ms: Keyword.get(opts, :max_age_ms)}}
  end

  @impl true
  def handle_call({:enqueue, nonce, frame}, _from, state) do
    cond do
      not valid_frame?(frame) ->
        {:reply, {:error, :invalid_frame}, state}

      not Mjolnir.AIE.Occupancy.accepted_design?(frame_get(frame, "design_id")) ->
        {:reply, {:error, :unknown_design}, state}

      Mjolnir.Secrets.Nonces.consume(nonce) != :ok ->
        {:reply, {:error, :nonce}, state}

      true ->
        id = "pnd_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

        row = %{
          pending_id: id,
          frame: stringify_keys(frame),
          job_digest: job_digest(frame),
          enqueue_mono_ms: now_ms(),
          status: :pending,
          attempt_id: nil
        }

        {:reply, {:ok, id}, put_in(state.rows[id], row)}
    end
  end

  def handle_call({:admit, pending_id, attempt_id, presented}, _from, state) do
    max_age = state.max_age_ms || Application.get_env(:mjolnir, :aie_max_queue_age_ms, 60_000)

    case Map.get(state.rows, pending_id) do
      nil ->
        {:reply, {:error, :unknown}, state}

      %{status: :cancelled} ->
        {:reply, {:error, :cancelled}, state}

      %{status: :expired} ->
        {:reply, {:error, :expired}, state}

      %{status: :dispatched, attempt_id: ^attempt_id} = row ->
        {:reply, {:ok, status_payload(row, :historical)}, state}

      %{status: :dispatched} ->
        {:reply, {:error, :already_dispatched}, state}

      %{status: :pending} = row ->
        age = now_ms() - row.enqueue_mono_ms

        cond do
          age > max_age ->
            row = %{row | status: :expired}
            {:reply, {:error, :expired}, put_in(state.rows[pending_id], row)}

          presented_mismatch?(row, presented) ->
            {:reply, {:error, :frame_mismatch}, state}

          true ->
            row = %{row | status: :dispatched, attempt_id: attempt_id}
            payload = status_payload(row, :live)
            {:reply, {:ok, payload}, put_in(state.rows[pending_id], row)}
        end
    end
  end

  def handle_call({:cancel, pending_id}, _from, state) do
    case Map.get(state.rows, pending_id) do
      nil ->
        {:reply, {:error, :unknown}, state}

      row ->
        {:reply, :ok, put_in(state.rows[pending_id], %{row | status: :cancelled})}
    end
  end

  def handle_call({:fetch, pending_id}, _from, state) do
    case Map.get(state.rows, pending_id) do
      nil -> {:reply, {:error, :unknown}, state}
      row -> {:reply, {:ok, row}, state}
    end
  end

  def handle_call(:reset, _from, state), do: {:reply, :ok, %{state | rows: %{}}}

  defp presented_mismatch?(row, presented) do
    digest = presented["job_digest"] || presented[:job_digest]
    resource = presented["resource"] || presented[:resource]
    digest != row.job_digest or (is_binary(resource) and resource != row.frame["resource"])
  end

  defp status_payload(row, kind) do
    %{
      "pending_id" => row.pending_id,
      "attempt_id" => row.attempt_id,
      "status" => "dispatched",
      "kind" => Atom.to_string(kind),
      "job_digest" => row.job_digest,
      "resource" => row.frame["resource"]
    }
  end

  defp frame_get(frame, key) do
    stringify_keys(frame)[key]
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
