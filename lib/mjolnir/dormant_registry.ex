defmodule Mjolnir.DormantRegistry do
  @moduledoc """
  Registry of dormant (checkpointed) VMs.

  When a VM signals "done", it gets BTRFS-snapshotted and stopped.
  This registry tracks the dormant state so the VM can be restored
  when a message arrives for it.

  Each entry stores the snapshot name, original config for restore,
  and a queue of messages that arrived while the VM was dormant.
  """

  use GenServer
  require Logger

  defstruct entries: %{}

  @type dormant_entry :: %{
          vm_id: String.t(),
          snapshot_name: String.t(),
          dormant_since: DateTime.t(),
          original_config: map(),
          pending_messages: [{String.t(), term()}],
          state: :dormant | :restoring
        }

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a VM as dormant with its snapshot name and original config.
  """
  @spec register(String.t(), String.t(), map()) :: :ok
  def register(vm_id, snapshot_name, original_config) do
    GenServer.call(__MODULE__, {:register, vm_id, snapshot_name, original_config})
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
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:register, vm_id, snapshot_name, original_config}, _from, state) do
    entry = %{
      vm_id: vm_id,
      snapshot_name: snapshot_name,
      dormant_since: DateTime.utc_now(),
      original_config: original_config,
      pending_messages: [],
      state: :dormant
    }

    Logger.info("Registered dormant VM #{vm_id} (snapshot: #{snapshot_name})")
    {:reply, :ok, %{state | entries: Map.put(state.entries, vm_id, entry)}}
  end

  def handle_call({:lookup, vm_id}, _from, state) do
    case Map.get(state.entries, vm_id) do
      nil -> {:reply, :not_found, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

  def handle_call({:unregister, vm_id}, _from, state) do
    Logger.info("Unregistered dormant VM #{vm_id}")
    {:reply, :ok, %{state | entries: Map.delete(state.entries, vm_id)}}
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
        {:reply, :ok, %{state | entries: Map.put(state.entries, vm_id, updated)}}
    end
  end

  def handle_call({:take_pending_messages, vm_id}, _from, state) do
    case Map.get(state.entries, vm_id) do
      nil ->
        {:reply, [], state}

      entry ->
        messages = entry.pending_messages
        updated = %{entry | pending_messages: []}
        {:reply, messages, %{state | entries: Map.put(state.entries, vm_id, updated)}}
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
        {:reply, :ok, %{state | entries: Map.put(state.entries, vm_id, updated)}}
    end
  end

  def handle_call({:cancel_restore, vm_id}, _from, state) do
    case Map.get(state.entries, vm_id) do
      nil ->
        {:reply, :ok, state}

      entry ->
        updated = %{entry | state: :dormant}
        {:reply, :ok, %{state | entries: Map.put(state.entries, vm_id, updated)}}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.entries), state}
  end
end
