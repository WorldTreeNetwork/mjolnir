defmodule Mjolnir.Gateway.RouteReconcilerTest do
  # Not async: subscribes to the shared EventBus :pg scope and asserts on
  # published-event fan-out.
  use ExUnit.Case, async: false

  alias Mjolnir.EventBus
  alias Mjolnir.Gateway.RouteReconciler

  # Start a reconciler whose render is fully stubbed: it just pings the test pid
  # with the rendered route count. No /etc writes, no systemctl.
  defp start_reconciler(opts \\ []) do
    test_pid = self()

    render_opts = [
      registry_entries: [],
      extra_domains: Keyword.get(opts, :extra_domains, []),
      running_vm_ids: Keyword.get(opts, :running_vm_ids, []),
      apexes: ["identikey.io"],
      ip_resolver: fn _ -> "10.0.0.1" end,
      path:
        Path.join([
          System.tmp_dir!(),
          "mjolnir-reconciler-test",
          "#{System.unique_integer([:positive])}.toml"
        ]),
      reload: fn -> send(test_pid, :rendered) end
    ]

    name = :"reconciler_#{System.unique_integer([:positive])}"

    init_args = [
      name: name,
      debounce_ms: Keyword.get(opts, :debounce_ms, 50),
      # Default to none so existing tests see exactly one boot render.
      settle_delays_ms: Keyword.get(opts, :settle_delays_ms, []),
      render_opts: render_opts
    ]

    {:ok, pid} =
      start_supervised(%{
        id: name,
        start: {RouteReconciler, :start_link, [init_args]}
      })

    on_exit(fn -> File.rm_rf!(Path.dirname(render_opts[:path])) end)
    {pid, name}
  end

  test "renders once on boot" do
    {_pid, _name} = start_reconciler()
    assert_receive :rendered, 500
  end

  test "debounces a burst of events into a single render" do
    {_pid, _name} = start_reconciler(debounce_ms: 100)
    # consume the boot render
    assert_receive :rendered, 500

    # Fire a burst faster than the debounce window.
    for _ <- 1..5, do: EventBus.publish("vm-x", :vm_started, %{})

    assert_receive :rendered, 500
    # Only one coalesced render for the whole burst.
    refute_receive :rendered, 250
  end

  test "ignores non-trigger events" do
    {_pid, _name} = start_reconciler(debounce_ms: 50)
    assert_receive :rendered, 500

    EventBus.publish("vm-x", :agent_event, %{})
    refute_receive :rendered, 250
  end

  test "trigger/0 is a safe no-op when the reconciler is not running" do
    assert RouteReconciler.trigger(
             :"definitely_not_running_#{System.unique_integer([:positive])}"
           ) ==
             :ok
  end

  test "trigger/1 schedules a render" do
    {_pid, name} = start_reconciler(debounce_ms: 50)
    assert_receive :rendered, 500

    assert RouteReconciler.trigger(name) == :ok
    assert_receive :rendered, 500
  end

  describe "post-boot settle sweep (mjolnir-do5)" do
    test "re-renders after boot so VMs that were still resuming get routes" do
      # The boot render fires before service VMs finish resuming, sees them as
      # not-running, and emits no route for their custom domains. Nothing used
      # to re-trigger afterwards, so the route stayed missing until some
      # unrelated VM event happened — on 2026-08-07 that meant a customer domain
      # 400ed until an operator noticed.
      {_pid, _name} = start_reconciler(settle_delays_ms: [60, 120])

      # Boot render, then one per settle delay.
      assert_receive :rendered, 1_000
      assert_receive :rendered, 1_000
      assert_receive :rendered, 1_000
    end

    test "the sweep is enabled by default, not just when a test configures it" do
      # Guards the DEFAULT. The tests below inject :settle_delays_ms, so they
      # would keep passing if the default were emptied — which is precisely the
      # regression (a boot render with no follow-up drops live routes).
      delays = RouteReconciler.default_settle_delays_ms()

      refute Enum.empty?(delays),
             "post-boot settle sweep is disabled; a boot render that races VM " <>
               "resume would drop customer routes permanently (mjolnir-do5)"

      assert Enum.all?(delays, &(is_integer(&1) and &1 > 0))

      assert Enum.max(delays) >= 60_000,
             "the last sweep must land after VM resume realistically completes"
    end

    test "the settle pass leaves the debounce chain working" do
      # Settle renders are sent as their own message precisely so they neither
      # cancel nor get cancelled by the debounce timer. Delays are chosen so the
      # two passes cannot coalesce: boot at ~30ms, settle at ~300ms.
      {_pid, name} = start_reconciler(debounce_ms: 30, settle_delays_ms: [300])

      assert_receive :rendered, 1_000, "boot render"
      assert_receive :rendered, 2_000, "settle render"

      # A later trigger must still produce its own render.
      RouteReconciler.trigger(name)
      assert_receive :rendered, 1_000, "triggered render after the settle pass"
    end
  end
end
