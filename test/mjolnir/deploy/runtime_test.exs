defmodule Mjolnir.Deploy.RuntimeTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Deploy.Runtime

  @plan %{start_command: "node build/index.js", port: 3000}
  @release "deploy-abc123"
  @domain "vm.example.test"

  # Recording ops seam. `prev` seeds Registry.get (a previous service VM for the
  # cutover path); `ticket_after` makes get_ticket return :not_ready N times
  # before yielding the ticket, exercising the await loop.
  defp recording_ops(agent, opts) do
    ticket = Keyword.get(opts, :ticket, "zticketzzz")
    not_ready_times = Keyword.get(opts, :not_ready_times, 0)
    prev = Keyword.get(opts, :prev)
    spawn_result = Keyword.get(opts, :spawn_result, {:ok, %{id: "svc-vm-1"}})
    exec_fail_on = Keyword.get(opts, :exec_fail_on)

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    %{
      spawn: fn boot ->
        Agent.update(agent, &[{:spawn, boot} | &1])
        spawn_result
      end,
      get_ticket: fn vm_id ->
        n = Agent.get_and_update(counter, &{&1, &1 + 1})
        Agent.update(agent, &[{:get_ticket, vm_id} | &1])
        if n < not_ready_times, do: {:error, :not_ready}, else: {:ok, ticket}
      end,
      exec: fn vm_id, cmd, _o ->
        Agent.update(agent, &[{:exec, vm_id, cmd} | &1])

        if exec_fail_on && String.contains?(cmd, exec_fail_on),
          do: {:error, {:exit_code, 1, "boom"}},
          else: {:ok, ""}
      end,
      registry_get: fn app ->
        Agent.update(agent, &[{:registry_get, app} | &1])
        if prev, do: {:ok, %{service_vm_id: prev}}, else: {:error, :not_found}
      end,
      registry_put: fn app, attrs ->
        Agent.update(agent, &[{:registry_put, app, attrs} | &1])
        {:ok, attrs}
      end,
      stop: fn vm_id ->
        Agent.update(agent, &[{:stop, vm_id} | &1])
        :ok
      end
    }
  end

  defp events(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()

  setup do
    {:ok, agent} = start_supervised({Agent, fn -> [] end})
    %{agent: agent}
  end

  describe "start/4 — happy path" do
    test "boots from the release, installs the unit, registers, returns URL", %{agent: agent} do
      ops = recording_ops(agent, [])

      assert {:ok, r} =
               Runtime.start("my-app", @release, @plan,
                 ops: ops,
                 gateway_domain: @domain,
                 ticket_timeout: 5_000
               )

      assert r.service_vm_id == "svc-vm-1"
      assert r.url == "https://zticketzzz-3000.#{@domain}"
      assert r.release_snapshot == @release
      assert r.unit =~ "PORT=3000"

      ev = events(agent)

      # Spawned from the release snapshot with Iroh on.
      assert {:spawn, boot} = Enum.find(ev, &match?({:spawn, _}, &1))
      assert boot[:snapshot] == @release
      assert boot[:enable_iroh] == true

      # Unit written then activated, in order.
      execs = for {:exec, _vm, cmd} <- ev, do: cmd
      assert [write, activate] = execs
      assert write =~ "mkdir -p /app"
      assert write =~ "cat > /etc/systemd/system/my-app.service"
      assert write =~ "ExecStart=/bin/sh -lc 'node build/index.js'"
      assert activate =~ "daemon-reload"
      assert activate =~ "enable --now my-app.service"

      # Registered with the derived URL.
      assert {:registry_put, "my-app", attrs} = Enum.find(ev, &match?({:registry_put, _, _}, &1))
      assert attrs.url == r.url
      assert attrs.service_vm_id == "svc-vm-1"

      # No previous VM → nothing stopped.
      refute Enum.any?(ev, &match?({:stop, _}, &1))
    end
  end

  describe "start/4 — ticket readiness" do
    test "polls get_ticket until the Iroh identity is ready", %{agent: agent} do
      ops = recording_ops(agent, not_ready_times: 3)

      assert {:ok, r} =
               Runtime.start("app", @release, @plan, ops: ops, gateway_domain: @domain)

      assert r.ticket == "zticketzzz"
      # 3 not-ready polls + 1 success.
      assert Enum.count(events(agent), &match?({:get_ticket, _}, &1)) == 4
    end
  end

  describe "start/4 — cutover" do
    test "stops the previous service VM after the new one registers", %{agent: agent} do
      ops = recording_ops(agent, prev: "old-svc-vm")

      assert {:ok, _r} = Runtime.start("app", @release, @plan, ops: ops, gateway_domain: @domain)

      ev = events(agent)
      # Registry put happens before the old VM is stopped (new is live first).
      put_idx = Enum.find_index(ev, &match?({:registry_put, _, _}, &1))
      stop_idx = Enum.find_index(ev, &match?({:stop, "old-svc-vm"}, &1))
      assert put_idx < stop_idx
    end
  end

  describe "start/4 — failure handling" do
    test "tears the VM down if unit installation fails", %{agent: agent} do
      ops = recording_ops(agent, exec_fail_on: "daemon-reload")

      assert {:error, {:unit_install_failed, {:exit_code, 1, _}}} =
               Runtime.start("app", @release, @plan, ops: ops, gateway_domain: @domain)

      # The just-booted VM is stopped; nothing is registered.
      ev = events(agent)
      assert Enum.any?(ev, &match?({:stop, "svc-vm-1"}, &1))
      refute Enum.any?(ev, &match?({:registry_put, _, _}, &1))
    end

    test "surfaces a spawn failure without execing or registering", %{agent: agent} do
      ops = recording_ops(agent, spawn_result: {:error, :no_kvm})

      assert {:error, {:spawn_failed, :no_kvm}} =
               Runtime.start("app", @release, @plan, ops: ops, gateway_domain: @domain)

      tags = events(agent) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      assert tags == [:spawn]
    end
  end

  describe "pure helpers" do
    test "unit_name slugifies and falls back to app.service" do
      assert Runtime.unit_name("My App!") == "my-app.service"
      assert Runtime.unit_name("Cool_App-1") == "cool_app-1.service"
      assert Runtime.unit_name("***") == "app.service"
    end

    test "gateway_url inserts the port before the domain" do
      assert Runtime.gateway_url("zzz", 8080, "vm.example.test") ==
               "https://zzz-8080.vm.example.test"
    end

    test "systemd_unit escapes single quotes in the start command" do
      unit = Runtime.systemd_unit("app", "sh -c 'echo hi'", 3000, "/srv")
      assert unit =~ "WorkingDirectory=/srv"
      assert unit =~ "ExecStart=/bin/sh -lc 'sh -c '\\''echo hi'\\'''"
    end
  end
end
