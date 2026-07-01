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
end
