defmodule Mjolnir.DormantRegistry do
  @moduledoc """
  Registry of dormant (checkpointed) VMs.

  When a VM signals "done", it gets BTRFS-snapshotted and stopped.
  This registry tracks the dormant state so the VM can be restored
  when a message arrives for it.

  Each entry stores the snapshot name, original config for restore,
  owner_id for multi-tenancy, and a queue of messages that arrived
  while the VM was dormant.

  State is persisted to `{btrfs_root}/@dormant/registry.json` with debounced
  writes (coalesced within 100ms) and restored on startup. A final synchronous
  flush runs on shutdown to prevent data loss.
  """

  use GenServer
  require Logger

  defstruct entries: %{}, dirty: false, flush_ref: nil

  @flush_delay_ms 100

  @type dormant_entry :: %{
          vm_id: String.t(),
          snapshot_name: String.t(),
          dormant_since: DateTime.t(),
          original_config: map(),
          owner_id: String.t() | nil,
          pending_messages: [{String.t(), term()}],
          state: :dormant | :restoring
        }

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register a VM as dormant with its snapshot name, original config, and owner.
  """
  @spec register(String.t(), String.t(), map(), String.t() | nil) :: :ok
  def register(vm_id, snapshot_name, original_config, owner_id \\ nil) do
    GenServer.call(__MODULE__, {:register, vm_id, snapshot_name, original_config, owner_id})
  end

  @doc """
  Look up a dormant VM by its ID.

  Returns `{:ok, entry}` or `:not_found`.
  """
  @spec lookup(String.t()) :: {:ok, dormant_entry()} | :not_found
  def lookup(vm_id) do
    GenServer.call(__MODULE__, {:lookup, vm_id})
  end

  @doc """
  Remove a VM from the dormant registry (e.g., after successful restore).
  """
  @spec unregister(String.t()) :: :ok
  def unregister(vm_id) do
    GenServer.call(__MODULE__, {:unregister, vm_id})
  end

  @doc """
  Queue a message for a dormant VM.
  """
  @spec queue_message(String.t(), String.t(), term()) :: :ok | {:error, :not_found}
  def queue_message(vm_id, from_vm_id, payload) do
    GenServer.call(__MODULE__, {:queue_message, vm_id, from_vm_id, payload})
  end

  @doc """
  Take all pending messages for a VM, clearing the queue.

  Returns a list of `{from_vm_id, payload}` tuples.
  """
  @spec take_pending_messages(String.t()) :: [{String.t(), term()}]
  def take_pending_messages(vm_id) do
    GenServer.call(__MODULE__, {:take_pending_messages, vm_id})
  end

  @doc """
  Transition a dormant VM to :restoring state.

  Returns `:ok` if the transition succeeded, `:already_restoring` if
  a restore is already in progress.
  """
  @spec begin_restore(String.t()) :: :ok | :already_restoring | {:error, :not_found}
  def begin_restore(vm_id) do
    GenServer.call(__MODULE__, {:begin_restore, vm_id})
  end

  @doc """
  Cancel a restore in progress, returning the VM to :dormant state.
  """
  @spec cancel_restore(String.t()) :: :ok
  def cancel_restore(vm_id) do
    GenServer.call(__MODULE__, {:cancel_restore, vm_id})
  end

  @doc """
  List all dormant VMs.
  """
  @spec list() :: [dormant_entry()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %__MODULE__{entries: load_from_disk()}
    {:ok, state}
  end

  @impl true
  def handle_call({:register, vm_id, snapshot_name, original_config, owner_id}, _from, state) do
    entry = %{
      vm_id: vm_id,
      snapshot_name: snapshot_name,
      dormant_since: DateTime.utc_now(),
      original_config: original_config,
      owner_id: owner_id,
      pending_messages: [],
      state: :dormant
    }

    Logger.info(
      "Registered dormant VM #{vm_id} (snapshot: #{snapshot_name}, owner: #{owner_id || "nil"})"
    )

    new_state = %{state | entries: Map.put(state.entries, vm_id, entry)}
    {:reply, :ok, schedule_flush(new_state)}
  end

  def handle_call({:lookup, vm_id}, _from, state) do
    case Map.get(state.entries, vm_id) do
      nil -> {:reply, :not_found, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

  def handle_call({:unregister, vm_id}, _from, state) do
    Logger.info("Unregistered dormant VM #{vm_id}")
    new_state = %{state | entries: Map.delete(state.entries, vm_id)}
    {:reply, :ok, schedule_flush(new_state)}
  end

  def handle_call({:queue_message, vm_id, from_vm_id, payload}, _from, state) do
    case Map.get(state.entries, vm_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{state: :restoring} ->
        # Reject queuing to a VM that is actively being restored — the caller
        # should route directly to the VM via VMRegistry instead.
        {:reply, {:error, :restoring}, state}

      entry ->
        updated = %{entry | pending_messages: entry.pending_messages ++ [{from_vm_id, payload}]}
        new_state = %{state | entries: Map.put(state.entries, vm_id, updated)}
        {:reply, :ok, schedule_flush(new_state)}
    end
  end

  def handle_call({:take_pending_messages, vm_id}, _from, state) do
    case Map.get(state.entries, vm_id) do
      nil ->
        {:reply, [], state}

      entry ->
        messages = entry.pending_messages
        updated = %{entry | pending_messages: []}
        new_state = %{state | entries: Map.put(state.entries, vm_id, updated)}
        {:reply, messages, schedule_flush(new_state)}
    end
  end

  def handle_call({:begin_restore, vm_id}, _from, state) do
    case Map.get(state.entries, vm_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{state: :restoring} ->
        {:reply, :already_restoring, state}

      %{state: :dormant} = entry ->
        updated = %{entry | state: :restoring}
        Logger.info("Beginning restore of dormant VM #{vm_id}")
        new_state = %{state | entries: Map.put(state.entries, vm_id, updated)}
        {:reply, :ok, schedule_flush(new_state)}
    end
  end

  def handle_call({:cancel_restore, vm_id}, _from, state) do
    case Map.get(state.entries, vm_id) do
      nil ->
        {:reply, :ok, state}

      entry ->
        updated = %{entry | state: :dormant}
        new_state = %{state | entries: Map.put(state.entries, vm_id, updated)}
        {:reply, :ok, schedule_flush(new_state)}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.entries), state}
  end

  @doc false
  def handle_call(:flush_now, _from, state) do
    # Synchronous flush for testing — bypasses debounce
    new_state = do_flush(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:flush, state) do
    {:noreply, do_flush(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Final synchronous flush on shutdown to prevent data loss
    if state.dirty do
      persist_to_disk(state.entries)
    end

    :ok
  end

  # ============================================================================
  # Flush Scheduling
  # ============================================================================

  defp schedule_flush(state) do
    # Cancel any pending flush timer
    if state.flush_ref, do: Process.cancel_timer(state.flush_ref)
    ref = Process.send_after(self(), :flush, @flush_delay_ms)
    %{state | dirty: true, flush_ref: ref}
  end

  defp do_flush(%{dirty: false} = state), do: state

  defp do_flush(state) do
    persist_to_disk(state.entries)
    %{state | dirty: false, flush_ref: nil}
  end

  # ============================================================================
  # Disk Persistence
  # ============================================================================

  defp registry_path do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root, "/var/lib/mjolnir/btrfs")
    Path.join([btrfs_root, "@dormant", "registry.json"])
  end

  defp persist_to_disk(entries) do
    path = registry_path()

    serializable =
      entries
      |> Enum.map(fn {vm_id, entry} ->
        {vm_id,
         %{
           vm_id: entry.vm_id,
           snapshot_name: entry.snapshot_name,
           dormant_since: DateTime.to_iso8601(entry.dormant_since),
           original_config: entry.original_config,
           owner_id: entry.owner_id,
           pending_messages:
             Enum.map(entry.pending_messages, fn {from_id, payload} ->
               %{from_vm_id: from_id, payload: payload}
             end),
           state: to_string(entry.state)
         }}
      end)
      |> Map.new()

    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        case File.write(path, Jason.encode!(serializable, pretty: true)) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to persist dormant registry: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("Failed to create dormant registry directory: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("Failed to persist dormant registry: #{inspect(e)}")
  end

  defp load_from_disk do
    path = registry_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} when is_map(data) ->
            entries =
              data
              |> Enum.map(fn {vm_id, raw} ->
                {vm_id,
                 %{
                   vm_id: raw["vm_id"] || vm_id,
                   snapshot_name: raw["snapshot_name"],
                   dormant_since: parse_datetime(raw["dormant_since"]),
                   original_config: raw["original_config"] || %{},
                   owner_id: raw["owner_id"],
                   pending_messages: deserialize_messages(raw["pending_messages"]),
                   state: :dormant
                 }}
              end)
              |> Map.new()

            Logger.info("Restored #{map_size(entries)} dormant entries from disk")
            entries

          {:ok, _} ->
            Logger.warning("Dormant registry file has unexpected format, starting fresh")
            %{}

          {:error, reason} ->
            Logger.warning(
              "Failed to parse dormant registry JSON: #{inspect(reason)}, starting fresh"
            )

            %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("Failed to read dormant registry: #{inspect(reason)}, starting fresh")
        %{}
    end
  end

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_datetime(_), do: DateTime.utc_now()

  defp deserialize_messages(nil), do: []

  defp deserialize_messages(messages) when is_list(messages) do
    Enum.map(messages, fn
      %{"from_vm_id" => from_id, "payload" => payload} -> {from_id, payload}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp deserialize_messages(_), do: []
end
