defmodule Mjolnir.Forge.EventBusTest do
  @moduledoc """
  Pub/sub fan-out for `Mjolnir.Forge.EventBus`. Not async — `:pg` membership is
  process-global within the node.
  """

  use ExUnit.Case, async: false

  alias Mjolnir.Forge.{EventBus, Events}

  defp event(host, type), do: Events.new(host: host, type: type)

  setup do
    # Each test subscribes itself; make sure we leave on the way out so a
    # later test's publish doesn't deliver here.
    on_exit(fn ->
      EventBus.unsubscribe(:all)
    end)

    :ok
  end

  test ":all subscribers receive every event regardless of host" do
    EventBus.subscribe(:all)
    EventBus.publish(event("self", :probe))

    assert_receive {:forge_event, %Events.Event{host: "self", type: :probe}}, 500
  end

  test "{:host, h} subscribers only receive that host's events" do
    EventBus.subscribe({:host, "host-a"})
    on_exit(fn -> EventBus.unsubscribe({:host, "host-a"}) end)

    EventBus.publish(event("host-b", :drift))
    refute_receive {:forge_event, _}, 100

    EventBus.publish(event("host-a", :drift))
    assert_receive {:forge_event, %Events.Event{host: "host-a"}}, 500
  end

  test "a host event reaches both the host subscriber and an :all subscriber" do
    EventBus.subscribe(:all)
    EventBus.subscribe({:host, "dual"})
    on_exit(fn -> EventBus.unsubscribe({:host, "dual"}) end)

    EventBus.publish(event("dual", :apply))

    # Delivered once per matching group → two messages to this process.
    assert_receive {:forge_event, %Events.Event{host: "dual"}}, 500
    assert_receive {:forge_event, %Events.Event{host: "dual"}}, 500
  end

  test "publish with no subscribers is a no-op (returns :ok)" do
    assert EventBus.publish(event("nobody", :probe)) == :ok
  end
end
