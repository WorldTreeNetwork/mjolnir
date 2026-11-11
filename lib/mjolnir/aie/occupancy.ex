defmodule Mjolnir.AIE.Occupancy do
  @moduledoc """
  Occupancy protocol for one host-catalog AIE job (ADR 0015 Decision 6/7).

  Try-lock, then admit under a deadline, then load or release. Load
  requires a live admit success on the current `attempt_id` while the
  lock is held and the deadline is live. Cached `dispatched` after
  abandon is status only. Guest xclbin paths are refused. The worker
  must inherit the flock fd; a live worker without inherit fails closed
  even if try-lock appears to succeed (spike aie-occupancy-lock).
  """

  use GenServer

  @default_catalog ["vector-add", "validate", "npu2-vector-add"]

  defstruct holder: nil, historical: %{}, loaded: MapSet.new(), admit_deadline_ms: 5_000

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @spec catalog() :: MapSet.t(String.t())
  def catalog do
    Application.get_env(:mjolnir, :aie_catalog_ids, @default_catalog) |> MapSet.new()
  end

  @spec accepted_design?(term()) :: boolean()
  def accepted_design?(id) when is_binary(id) do
    MapSet.member?(catalog(), id) and not guest_xclbin?(id)
  end

  def accepted_design?(_), do: false

  @spec guest_xclbin?(String.t()) :: boolean()
  def guest_xclbin?(id) when is_binary(id) do
    String.contains?(id, "/") or String.ends_with?(id, ".xclbin") or
      String.contains?(id, "\\")
  end

  @spec try_lock(GenServer.server(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def try_lock(server, opts \\ []) do
    GenServer.call(server, {:try_lock, opts})
  end

  @spec mark_live_success(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, atom()}
  def mark_live_success(server, attempt_id, pending_id) do
    GenServer.call(server, {:mark_live_success, attempt_id, pending_id})
  end

  @spec authorize_load(GenServer.server(), String.t(), String.t(), keyword()) ::
          :ok | {:error, atom()}
  def authorize_load(server, pending_id, attempt_id, opts \\ []) do
    GenServer.call(server, {:authorize_load, pending_id, attempt_id, opts})
  end

  @spec start_worker(GenServer.server(), String.t(), (-> any()), keyword()) ::
          :ok | {:error, atom()}
  def start_worker(server, attempt_id, fun, opts \\ []) when is_function(fun, 0) do
    GenServer.call(server, {:start_worker, attempt_id, fun, opts})
  end

  @spec await_quiescence(GenServer.server(), String.t(), timeout()) :: :ok | {:error, atom()}
  def await_quiescence(server, attempt_id, timeout \\ 5_000) do
    GenServer.call(server, {:await_quiescence, attempt_id}, timeout + 100)
  end

  @spec release(GenServer.server(), String.t()) :: :ok | {:error, atom()}
  def release(server, attempt_id), do: GenServer.call(server, {:release, attempt_id})

  @spec abandon(GenServer.server(), String.t()) :: :ok
  def abandon(server, attempt_id), do: GenServer.call(server, {:abandon, attempt_id})

  @spec holding?(GenServer.server()) :: boolean()
  def holding?(server), do: GenServer.call(server, :holding?)

  @spec historical?(GenServer.server(), String.t(), String.t()) :: boolean()
  def historical?(server, pending_id, attempt_id) do
    GenServer.call(server, {:historical?, pending_id, attempt_id})
  end

  @impl true
  def init(opts) do
    deadline = Keyword.get(opts, :admit_deadline_ms, default_deadline())
    {:ok, %__MODULE__{admit_deadline_ms: deadline}}
  end

  @impl true
  def handle_call({:try_lock, opts}, _from, state) do
    cond do
      state.holder != nil ->
        {:reply, {:error, :occupied}, state}

      live_worker_without_inherit?(opts) ->
        {:reply, {:error, :live_worker}, state}

      true ->
        attempt_id = "att_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
        deadline_ms = Keyword.get(opts, :deadline_ms, state.admit_deadline_ms)
        tref = Process.send_after(self(), {:expire, attempt_id}, deadline_ms)

        holder = %{
          attempt_id: attempt_id,
          deadline_ref: tref,
          deadline_ms: deadline_ms,
          live_success: false,
          pending_id: nil,
          loaded: false,
          worker: nil,
          inherit: Keyword.get(opts, :inherited_flock?, true),
          abandoned: false,
          wall_ref: nil,
          had_worker: false
        }

        {:reply, {:ok, %{attempt_id: attempt_id}}, %{state | holder: holder}}
    end
  end

  def handle_call({:mark_live_success, attempt_id, pending_id}, _from, state) do
    case state.holder do
      %{attempt_id: ^attempt_id, abandoned: false} = holder ->
        holder = %{holder | live_success: true, pending_id: pending_id}
        hist = Map.put(state.historical, {pending_id, attempt_id}, :dispatched)
        {:reply, :ok, %{state | holder: holder, historical: hist}}

      %{attempt_id: ^attempt_id} ->
        hist = Map.put(state.historical, {pending_id, attempt_id}, :dispatched)
        {:reply, {:error, :abandoned}, %{state | historical: hist}}

      _ ->
        {:reply, {:error, :wrong_attempt}, state}
    end
  end

  def handle_call({:authorize_load, pending_id, attempt_id, opts}, _from, state) do
    design_id = Keyword.get(opts, :design_id)

    cond do
      MapSet.member?(state.loaded, pending_id) ->
        {:reply, {:error, :already_loaded}, state}

      match?(%{attempt_id: ^attempt_id, abandoned: true}, state.holder) ->
        {:reply, {:error, :abandoned}, state}

      state.holder == nil ->
        {:reply, {:error, :abandoned}, state}

      state.holder.attempt_id != attempt_id ->
        {:reply, {:error, :wrong_attempt}, state}

      not state.holder.live_success or state.holder.pending_id != pending_id ->
        {:reply, {:error, :no_live_success}, state}

      is_binary(design_id) and not accepted_design?(design_id) ->
        {:reply, {:error, :unknown_design}, state}

      true ->
        holder = %{state.holder | loaded: true}
        loaded = MapSet.put(state.loaded, pending_id)
        {:reply, :ok, %{state | holder: holder, loaded: loaded}}
    end
  end

  def handle_call({:start_worker, attempt_id, fun, opts}, _from, state) do
    case state.holder do
      %{attempt_id: ^attempt_id, loaded: true, worker: nil} = holder ->
        {worker, _ref} = spawn_monitor(fun)
        wall = Keyword.get(opts, :wall_ms, 60_000)
        wref = Process.send_after(self(), {:kill_worker, attempt_id}, wall)
        holder = %{holder | worker: worker, wall_ref: wref, inherit: true, had_worker: true}
        {:reply, :ok, %{state | holder: holder}}

      %{attempt_id: ^attempt_id, loaded: false} ->
        {:reply, {:error, :not_loaded}, state}

      %{attempt_id: ^attempt_id, worker: pid} when is_pid(pid) ->
        {:reply, {:error, :already_loaded}, state}

      _ ->
        {:reply, {:error, :wrong_attempt}, state}
    end
  end

  def handle_call({:await_quiescence, attempt_id}, from, state) do
    case state.holder do
      %{attempt_id: ^attempt_id, worker: nil} ->
        {:reply, :ok, state}

      %{attempt_id: ^attempt_id} ->
        {:noreply, Map.put(state, :quiesce_from, from)}

      nil ->
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :wrong_attempt}, state}
    end
  end

  def handle_call({:release, attempt_id}, _from, state) do
    case state.holder do
      %{attempt_id: ^attempt_id, worker: pid} when is_pid(pid) ->
        {:reply, {:error, :busy}, state}

      %{attempt_id: ^attempt_id} = holder ->
        cancel_timer(holder)
        {:reply, :ok, %{state | holder: nil}}

      nil ->
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :wrong_attempt}, state}
    end
  end

  def handle_call({:abandon, attempt_id}, _from, state) do
    {:reply, :ok, do_abandon(state, attempt_id)}
  end

  def handle_call(:holding?, _from, state) do
    {:reply, state.holder != nil, state}
  end

  def handle_call({:historical?, pending_id, attempt_id}, _from, state) do
    {:reply, Map.has_key?(state.historical, {pending_id, attempt_id}), state}
  end

  @impl true
  def handle_info({:expire, attempt_id}, state) do
    {:noreply, do_abandon(state, attempt_id)}
  end

  def handle_info({:kill_worker, attempt_id}, state) do
    case state.holder do
      %{attempt_id: ^attempt_id, worker: pid} when is_pid(pid) ->
        Process.exit(pid, :kill)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case state.holder do
      %{worker: ^pid} = holder ->
        holder = %{holder | worker: nil, had_worker: true}
        state = %{state | holder: holder}
        state = reply_quiesce(state)
        {:noreply, maybe_auto_release(state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_auto_release(%{holder: %{worker: nil, had_worker: true}} = state) do
    cancel_timer(state.holder)
    %{state | holder: nil}
  end

  defp maybe_auto_release(state), do: state

  defp reply_quiesce(%{quiesce_from: from} = state) do
    GenServer.reply(from, :ok)
    Map.delete(state, :quiesce_from)
  end

  defp reply_quiesce(state), do: state

  defp do_abandon(state, attempt_id) do
    case state.holder do
      %{attempt_id: ^attempt_id, worker: pid} = holder when is_pid(pid) ->
        Process.exit(pid, :kill)
        cancel_timer(holder)
        %{state | holder: %{holder | abandoned: true, live_success: false}}

      %{attempt_id: ^attempt_id} = holder ->
        cancel_timer(holder)
        %{state | holder: nil}

      _ ->
        state
    end
  end

  defp cancel_timer(holder) do
    if is_reference(Map.get(holder, :deadline_ref)),
      do: Process.cancel_timer(holder.deadline_ref)

    if is_reference(Map.get(holder, :wall_ref)),
      do: Process.cancel_timer(holder.wall_ref)

    :ok
  end

  defp live_worker_without_inherit?(opts) do
    pid = Keyword.get(opts, :persisted_worker_pid)
    inherited? = Keyword.get(opts, :inherited_flock?, true)
    is_integer(pid) and pid > 0 and not inherited? and worker_alive?(pid)
  end

  defp worker_alive?(pid) when is_integer(pid) do
    File.exists?("/proc/#{pid}")
  end

  defp default_deadline do
    Application.get_env(:mjolnir, :aie_admit_deadline_ms, 5_000)
  end
end
