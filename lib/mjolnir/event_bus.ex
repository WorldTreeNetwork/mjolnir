defmodule Mjolnir.EventBus do
  @moduledoc """
  Local pub/sub event bus using :pg process groups.

  Subscribers can subscribe to events for a specific VM or all VMs.
  Events are delivered as messages to subscriber processes.

  Will be extended to distributed pub/sub via :pg across cluster in Phase 4.

  ## Event Types

  - `:vm_spawned` - A new VM has been created
  - `:vm_stopped` - A VM has been stopped
  - `:snapshot_created` - A VM snapshot was created
  - `:agent_event` - Event forwarded from guest agent

  ## Event Format

  Events are delivered as messages: `{:mjolnir_event, vm_id, event_type, payload}`

  ## Examples

      # Subscribe to all events for a specific VM
      EventBus.subscribe(vm_id)

      # Subscribe to all VM events
      EventBus.subscribe(:all)

      # Publish an event
      EventBus.publish(vm_id, :vm_spawned, %{vcpus: 2, memory_mb: 512})

      # Receive events in your process
      receive do
        {:mjolnir_event, vm_id, event_type, payload} ->
          IO.puts("Received event: \#{event_type} for \#{vm_id}")
      end
  """

  @pg_scope :mjolnir_events

  @doc false
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {:pg, :start_link, [@pg_scope]},
      type: :worker
    }
  end

  @doc """
  Returns the :pg scope name used by the event bus.

  Primarily for testing purposes.
  """
  def pg_scope, do: @pg_scope

  @doc """
  Subscribe calling process to events.

  Can subscribe to:
  - A specific VM by passing the `vm_id` string
  - All VMs by passing `:all`

  The process will receive messages in the format:
  `{:mjolnir_event, vm_id, event_type, payload}`
  """
  def subscribe(vm_id_or_all)

  def subscribe(vm_id) when is_binary(vm_id) do
    :pg.join(@pg_scope, {:vm, vm_id}, self())
  end

  def subscribe(:all) do
    :pg.join(@pg_scope, :all_events, self())
  end

  @doc """
  Unsubscribe calling process from events.

  Can unsubscribe from:
  - A specific VM by passing the `vm_id` string
  - All VMs by passing `:all`
  """
  def unsubscribe(vm_id_or_all)

  def unsubscribe(vm_id) when is_binary(vm_id) do
    :pg.leave(@pg_scope, {:vm, vm_id}, self())
  end

  def unsubscribe(:all) do
    :pg.leave(@pg_scope, :all_events, self())
  end

  @doc """
  Publish an event. Delivers to subscribers of the specific VM
  and to :all subscribers.

  Event message format: `{:mjolnir_event, vm_id, event_type, payload}`

  ## Examples

      EventBus.publish(vm_id, :vm_spawned, %{vcpus: 2})
      EventBus.publish(vm_id, :vm_stopped, %{})
      EventBus.publish(vm_id, :agent_event, %{type: "custom", data: "value"})
  """
  def publish(vm_id, event_type, payload \\ %{}) when is_binary(vm_id) and is_atom(event_type) do
    message = {:mjolnir_event, vm_id, event_type, payload}

    # Send to VM-specific subscribers
    for pid <- :pg.get_members(@pg_scope, {:vm, vm_id}) do
      send(pid, message)
    end

    # Send to :all subscribers
    for pid <- :pg.get_members(@pg_scope, :all_events) do
      send(pid, message)
    end

    :ok
  end
end
