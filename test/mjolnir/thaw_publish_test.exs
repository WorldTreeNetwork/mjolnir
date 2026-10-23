defmodule Mjolnir.ThawPublishTest do
  @moduledoc """
  The thaw publish gate. `Mjolnir.VM` calls `Mjolnir.Thaw.Publish.run/1` from
  `attach_thawed` before a restored VM gets a PTY, a ticket, or `:vm_started`.

  These tests call that function. The reseed, clock, and Iroh steps are
  injected so the decision runs without KVM. They are not a second copy of
  the decision.
  """
  use ExUnit.Case, async: true

  alias Mjolnir.Clock
  alias Mjolnir.Thaw.Publish

  defp ctx(overrides) do
    Map.merge(
      %{
        enable_iroh: false,
        boot_ping: :ok,
        reseed: fn -> :ok end,
        clock: fn -> :ok end,
        iroh: fn -> flunk("Iroh probe ran") end
      },
      Map.new(overrides)
    )
  end

  test "a failed clock step does not publish, even when the vsock ping and the reseed succeeded" do
    assert {:error, {:clock_refused, "old"}} =
             Publish.run(
               ctx(
                 clock: fn -> {:error, {:clock_refused, "old"}} end,
                 iroh: fn -> flunk("Iroh probe ran after a failed clock step") end
               )
             )
  end

  test "a vsock ping on its own does not publish" do
    probes = %{
      boot_ping: :ok,
      reseed: :error,
      clock: :error,
      monotonic_stepped: false,
      enable_iroh: true,
      iroh: {:error, :iroh_unreachable}
    }

    assert {:error, :unpublished} = Publish.decide(probes)
    assert :unhealthy = Publish.health(probes)
  end

  test "a dead Iroh endpoint does not publish and is unhealthy even though the agent answered ping" do
    probes = %{
      boot_ping: :ok,
      reseed: :ok,
      clock: :ok,
      monotonic_stepped: false,
      enable_iroh: true,
      iroh: {:error, :iroh_not_ready}
    }

    assert {:error, :unpublished} =
             Publish.run(
               ctx(
                 enable_iroh: true,
                 iroh: fn -> %{ready: false} end
               )
             )

    assert :unhealthy = Publish.health(probes)
    refute match?({:ok, %{iroh: %{node_id: _}}}, Publish.decide(probes))
  end

  test "a stubbed Iroh probe success publishes and is healthy" do
    info = %{ready: true, node_id: "abc123", ticket: "ticket-json"}

    assert {:ok, %{published: true, monotonic_stepped: false, iroh: ^info}} =
             Publish.run(ctx(enable_iroh: true, iroh: fn -> info end))

    assert :healthy =
             Publish.health(%{
               boot_ping: :ok,
               reseed: :ok,
               clock: :ok,
               monotonic_stepped: false,
               enable_iroh: true,
               iroh: {:ok, info}
             })
  end

  test "an Iroh timeout is not a publish" do
    assert {:error, :unpublished} =
             Publish.run(ctx(enable_iroh: true, iroh: fn -> nil end))

    assert {:error, :iroh_unreachable} = Publish.classify_iroh(nil)
  end

  test "reseed and wall-clock success publish without stepping monotonic time" do
    assert {:ok, %{published: true, monotonic_stepped: false, iroh: nil}} =
             Publish.run(ctx([]))
  end

  test "the clock request is host wall time and does not carry the park" do
    snapshot = 1_700_000_000
    park = 3 * 24 * 3_600
    {secs, nsec} = Clock.host_wall()
    req = Clock.request(secs, nsec, "clock-1")

    assert req["type"] == "set_wall_time"
    assert req["realtime_secs"] == secs
    assert req["realtime_nsec"] == nsec
    assert secs > snapshot + park
    refute Map.has_key?(req, "monotonic_secs")
    refute Map.has_key?(req, "boottime_secs")
    refute req["realtime_secs"] == snapshot + park
  end

  test "a guest still hours behind snapshot time is not accepted as host time" do
    requested = System.system_time(:second)
    snapshot = requested - 6 * 3_600

    assert {:error, {:clock_not_host_time, ^snapshot, ^requested}} =
             Clock.interpret(
               %{
                 "type" => "set_wall_time_response",
                 "ok" => true,
                 "monotonic_stepped" => false,
                 "realtime_secs" => snapshot
               },
               requested
             )

    assert {:error, {:clock_not_host_time, _, _}} =
             Publish.run(
               ctx(
                 clock: fn ->
                   Clock.interpret(
                     %{
                       "type" => "set_wall_time_response",
                       "ok" => true,
                       "monotonic_stepped" => false,
                       "realtime_secs" => snapshot
                     },
                     requested
                   )
                 end
               )
             )
  end

  test "a guest that reports host time and an unstepped monotonic clock is accepted" do
    requested = System.system_time(:second)

    assert :ok =
             Clock.interpret(
               %{
                 "type" => "set_wall_time_response",
                 "ok" => true,
                 "monotonic_stepped" => false,
                 "realtime_secs" => requested
               },
               requested
             )
  end

  test "a response that claims monotonic time was stepped is refused" do
    assert {:error, :monotonic_stepped} =
             Clock.interpret(
               %{
                 "type" => "set_wall_time_response",
                 "ok" => true,
                 "monotonic_stepped" => true,
                 "realtime_secs" => System.system_time(:second)
               },
               System.system_time(:second)
             )
  end

  test "an agent that does not know set_wall_time fails closed" do
    assert {:error, {:clock_unsupported_by_agent, "unknown type"}} =
             Clock.interpret(
               %{"type" => "error", "ok" => false, "error" => "unknown type"},
               System.system_time(:second)
             )
  end
end
