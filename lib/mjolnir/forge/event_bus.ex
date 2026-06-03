defmodule Mjolnir.Forge.EventBus do
  @moduledoc """
  Local pub/sub for Forge reconciliation events, using `:pg` process groups.

  A direct mirror of `Mjolnir.EventBus` — same `:pg`-per-scope shape, no
  Phoenix.PubSub dependency. Subscribers (typically SSE request handlers)
  receive `{:forge_event, %Mjolnir.Forge.Events.Event{}}` messages.

  Subscriptions:

    * `:all` — every Forge event, regardless of host
    * `{:host, host}` — only events for the given host

  Persistence is *not* this module's job. `Mjolnir.Forge.Events.emit/1`
  appends to `Mjolnir.Forge.AuditLog` (durable replay) and then calls
  `publish/1` here (live fan-out). This module is fire-and-forget: publishing
  with no subscribers is a no-op.
  """

  @scope :forge_events

  @doc false
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {:pg, :start_link, [@scope]},
      type: :worker
    }
  end

  @doc "The `:pg` scope name. Primarily for tests."
  def scope, do: @scope

  @doc """
  Subscribe the calling process to Forge events.

  Pass `:all` for every event, or `{:host, host}` to scope to one host.
  The process receives `{:forge_event, event}` messages.
  """
  @spec subscribe(:all | {:host, String.t()}) :: :ok
  def subscribe(:all), do: :pg.join(@scope, :all, self())
  def subscribe({:host, host}) when is_binary(host), do: :pg.join(@scope, {:host, host}, self())

  @doc "Unsubscribe the calling process."
  @spec unsubscribe(:all | {:host, String.t()}) :: :ok
  def unsubscribe(:all), do: :pg.leave(@scope, :all, self())

  def unsubscribe({:host, host}) when is_binary(host),
    do: :pg.leave(@scope, {:host, host}, self())

  @doc """
  Deliver an event to subscribers of its host and to `:all` subscribers.

  Returns `:ok`. Delivery is best-effort `send/2`; dead subscribers are
  pruned from `:pg` automatically when their process exits.
  """
  @spec publish(struct()) :: :ok
  def publish(%{host: host} = event) do
    message = {:forge_event, event}

    for pid <- :pg.get_members(@scope, {:host, host}), do: send(pid, message)
    for pid <- :pg.get_members(@scope, :all), do: send(pid, message)

    :ok
  end
end
