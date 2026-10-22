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
    prev_custom_domain = Keyword.get(opts, :prev_custom_domain)
    prev_stateful = Keyword.get(opts, :prev_stateful, false)
    spawn_result = Keyword.get(opts, :spawn_result, {:ok, %{id: "svc-vm-1"}})
    exec_fail_on = Keyword.get(opts, :exec_fail_on)

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # Model the real Registry: get after put returns the NEW entry. A stub that
    # always yields `prev` hides the cutover bug (Runtime used to re-get after
    # put, see prev == new, and leak the previous guest).
    initial_entry =
      if prev || prev_custom_domain do
        {:ok,
         %{service_vm_id: prev, custom_domain: prev_custom_domain, stateful: prev_stateful}}
      else
        {:error, :not_found}
      end

    {:ok, entry_box} = Agent.start_link(fn -> initial_entry end)

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
        Agent.get(entry_box, & &1)
      end,
      registry_put: fn app, attrs ->
        Agent.update(agent, &[{:registry_put, app, attrs} | &1])
        Agent.update(entry_box, fn _ -> {:ok, attrs} end)
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

  describe "start/4 — stateful adopt" do
    test "refuses cutover of a stateful app", %{agent: agent} do
      ops = recording_ops(agent, prev: "old-vm", prev_stateful: true)

      assert {:error, :stateful_app_refuses_redeploy} =
               Runtime.start("hive", @release, @plan,
                 ops: ops,
                 gateway_domain: @domain,
                 ticket_timeout: 5_000
               )

      refute Enum.any?(events(agent), &match?({:spawn, _}, &1))
    end

    test "force redeploy of a stateful app is allowed", %{agent: agent} do
      ops = recording_ops(agent, prev: "old-vm", prev_stateful: true)

      assert {:ok, r} =
               Runtime.start("hive", @release, @plan,
                 ops: ops,
                 gateway_domain: @domain,
                 ticket_timeout: 5_000,
                 force: true
               )

      assert r.service_vm_id == "svc-vm-1"
      assert {:spawn, _} = Enum.find(events(agent), &match?({:spawn, _}, &1))
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
      # The get-after-put stub returns the new id; stop must still target the old one.
      refute Enum.any?(ev, &match?({:stop, "svc-vm-1"}, &1))
    end
  end

  describe "start/4 — custom_domain preservation (gge.12.1)" do
    test "carries the prior entry's custom_domain into the new registry attrs", %{agent: agent} do
      ops = recording_ops(agent, prev: "old-svc-vm", prev_custom_domain: "zine.identikey.io")

      assert {:ok, _r} = Runtime.start("app", @release, @plan, ops: ops, gateway_domain: @domain)

      assert {:registry_put, "app", attrs} =
               Enum.find(events(agent), &match?({:registry_put, _, _}, &1))

      # Without the fix this key is absent → Registry builds a fresh Entry with
      # custom_domain: nil → RouteReconciler drops the app's route on redeploy.
      assert attrs.custom_domain == "zine.identikey.io"
    end

    test "records custom_domain: nil for a first deploy with no prior entry", %{agent: agent} do
      ops = recording_ops(agent, [])

      assert {:ok, _r} = Runtime.start("app", @release, @plan, ops: ops, gateway_domain: @domain)

      assert {:registry_put, "app", attrs} =
               Enum.find(events(agent), &match?({:registry_put, _, _}, &1))

      assert Map.get(attrs, :custom_domain) == nil
    end

    test "an explicit :custom_domain opt overrides the preserved value", %{agent: agent} do
      ops = recording_ops(agent, prev: "old-svc-vm", prev_custom_domain: "old.identikey.io")

      assert {:ok, _r} =
               Runtime.start("app", @release, @plan,
                 ops: ops,
                 gateway_domain: @domain,
                 custom_domain: "new.identikey.io"
               )

      assert {:registry_put, "app", attrs} =
               Enum.find(events(agent), &match?({:registry_put, _, _}, &1))

      assert attrs.custom_domain == "new.identikey.io"
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
      # registry_get runs first so a stateful app can refuse before spawn.
      assert tags == [:registry_get, :spawn]
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

  describe "start/4 — managed secrets gate" do
    # A :managed deploy hands the VM secrets expecting a LUKS volume at
    # /secrets. If the unlock failed, /secrets is an ordinary directory on the
    # ROOTFS — which is captured by @snapshots, by every deploy release layer,
    # and by @trash on delete. Starting the app there risks writing plaintext
    # secrets into all of them. Refuse, and take the VM down with us.
    test "refuses to start the service when the managed unlock failed", %{agent: agent} do
      ops =
        recording_ops(agent,
          spawn_result: {:ok, %{id: "svc-vm-1", secrets_unlock_failure: %{reason: ":timeout"}}}
        )

      assert {:error, {:secrets_unlock_failed, ":timeout"}} =
               Runtime.start("my-app", @release, @plan,
                 ops: ops,
                 gateway_domain: @domain,
                 spawn_opts: %{secrets_mode: :managed}
               )

      ev = events(agent)

      # Nothing was executed in the guest, and nothing was registered — no URL
      # is handed back for a service that is broken or leaking.
      refute Enum.any?(ev, &match?({:exec, _, _}, &1))
      refute Enum.any?(ev, &match?({:registry_put, _, _}, &1))

      # The VM is stopped: it must not be left one `systemctl start` away from
      # writing plaintext where an encrypted volume was supposed to be.
      assert Enum.any?(ev, &match?({:stop, "svc-vm-1"}, &1))
    end

    test "a successful managed unlock proceeds normally", %{agent: agent} do
      ops =
        recording_ops(agent, spawn_result: {:ok, %{id: "svc-vm-1", secrets_unlock_failure: nil}})

      assert {:ok, r} =
               Runtime.start("my-app", @release, @plan,
                 ops: ops,
                 gateway_domain: @domain,
                 spawn_opts: %{secrets_mode: :managed}
               )

      assert r.service_vm_id == "svc-vm-1"
      refute Enum.any?(events(agent), &match?({:stop, "svc-vm-1"}, &1))
    end

    test "a NON-managed deploy is unaffected even if the field is set" do
      # The gate is scoped to deploys that actually asked for secrets. A VM with
      # none has nothing to protect, and must not be blocked by a stale field.
      {:ok, agent} = Agent.start_link(fn -> [] end)

      ops =
        recording_ops(agent,
          spawn_result: {:ok, %{id: "svc-vm-1", secrets_unlock_failure: %{reason: ":timeout"}}}
        )

      assert {:ok, _} =
               Runtime.start("my-app", @release, @plan, ops: ops, gateway_domain: @domain)
    end
  end

  describe "systemd_unit/5 — secrets mount condition" do
    # Runtime.start/4 refuses the DEPLOY when the unlock fails, but that only
    # covers the deploy. This covers every restart afterwards — reboot, resume,
    # a manual `systemctl start`. Without it the first restart after a failed
    # unlock runs the app with /secrets as a plain directory on the rootfs,
    # which snapshots, release layers and @trash all capture.
    test "a :managed service is gated on /secrets being a real mount" do
      unit =
        Runtime.systemd_unit("my-app", "node build/index.js", 3000, "/app",
          secrets_mode: :managed
        )

      assert unit =~ "ConditionPathIsMountPoint=/secrets"

      # It belongs to [Unit], not [Service] — systemd only honours conditions there.
      [unit_section, service_section] = String.split(unit, "[Service]", parts: 2)
      assert unit_section =~ "ConditionPathIsMountPoint"
      refute service_section =~ "ConditionPathIsMountPoint"

      # A CONDITION, never a dependency: nothing creates a .mount unit for
      # /secrets (the guest agent mounts it directly), so RequiresMountsFor
      # would order against a unit that never appears and hang the boot.
      refute unit =~ "RequiresMountsFor"
    end

    test "a service with no managed secrets is not gated" do
      unit = Runtime.systemd_unit("my-app", "node build/index.js", 3000, "/app")
      refute unit =~ "ConditionPathIsMountPoint"

      for mode <- [:none, :ephemeral, :persistent] do
        refute Runtime.systemd_unit("my-app", "cmd", 3000, "/app", secrets_mode: mode) =~
                 "ConditionPathIsMountPoint"
      end
    end

    test "the rendered unit still parses as INI with the condition present" do
      # A stray blank line or a condition landing mid-section would be silently
      # ignored by systemd — the gate would look present and do nothing.
      unit =
        Runtime.systemd_unit("my-app", "cmd", 3000, "/app", secrets_mode: :managed)

      sections =
        unit
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "["))

      assert sections == ["[Unit]", "[Service]", "[Install]"]

      refute unit =~ "\n\n\n"
    end

    test "start/4 propagates the spawn's secrets_mode into the unit", %{agent: agent} do
      ops = recording_ops(agent, spawn_result: {:ok, %{id: "svc-vm-1"}})

      assert {:ok, r} =
               Runtime.start("my-app", @release, @plan,
                 ops: ops,
                 gateway_domain: @domain,
                 spawn_opts: %{secrets_mode: :managed}
               )

      assert r.unit =~ "ConditionPathIsMountPoint=/secrets"

      # And the unit that was actually written into the guest carries it too —
      # r.unit agreeing with itself proves nothing.
      execs = for {:exec, _vm, cmd} <- events(agent), do: cmd
      assert Enum.any?(execs, &(&1 =~ "ConditionPathIsMountPoint=/secrets"))
    end
  end

  # ---------------------------------------------------------------------------
  # mjolnir-c6s — the unit has to come back after a restart, not just stay safe
  # ---------------------------------------------------------------------------

  describe "secrets target ordering" do
    # The condition alone made a restarted app fail CLOSED but also fail
    # PERMANENTLY: systemd evaluates conditions when the job runs, and at boot
    # the passphrase has not arrived, so the unit was skipped and never
    # reconsidered. Being wanted by mjolnir-secrets.target instead means there
    # is no boot-time job at all — the agent starts the target once /secrets is
    # genuinely mounted.
    test "a :managed service is wanted by the secrets target, not multi-user" do
      unit = Runtime.systemd_unit("my-app", "cmd", 3000, "/app", secrets_mode: :managed)

      assert unit =~ "WantedBy=mjolnir-secrets.target"
      refute unit =~ "WantedBy=multi-user.target"
    end

    test "a plain service is still wanted by multi-user.target" do
      assert Runtime.systemd_unit("my-app", "cmd", 3000, "/app") =~ "WantedBy=multi-user.target"

      for mode <- [:none, :ephemeral, :persistent] do
        unit = Runtime.systemd_unit("my-app", "cmd", 3000, "/app", secrets_mode: mode)
        assert unit =~ "WantedBy=multi-user.target"
        refute unit =~ "mjolnir-secrets.target"
      end
    end

    test "a :managed service is ordered after the target" do
      unit = Runtime.systemd_unit("my-app", "cmd", 3000, "/app", secrets_mode: :managed)

      [unit_section, _] = String.split(unit, "[Service]", parts: 2)
      assert unit_section =~ "After=mjolnir-secrets.target"
    end

    test "the condition survives alongside the target ordering" do
      # Ordering handles boot; the condition handles a hand-run
      # `systemctl start app` while the volume is closed. Losing either one
      # reopens a path to plaintext on the rootfs.
      unit = Runtime.systemd_unit("my-app", "cmd", 3000, "/app", secrets_mode: :managed)

      assert unit =~ "ConditionPathIsMountPoint=/secrets"
      assert unit =~ "WantedBy=mjolnir-secrets.target"
    end

    test "the unit still parses as INI with both additions" do
      unit = Runtime.systemd_unit("my-app", "cmd", 3000, "/app", secrets_mode: :managed)

      sections = unit |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "["))
      assert sections == ["[Unit]", "[Service]", "[Install]"]
      refute unit =~ "\n\n\n"
    end

    test "the target unit itself is inert — nothing pulls it in at boot" do
      # An [Install] section here would defeat the entire mechanism: the target
      # would start at boot, before the passphrase, releasing the app early.
      body = Runtime.secrets_target_unit()

      assert body =~ "[Unit]"
      refute body =~ "[Install]"
      refute body =~ "WantedBy"
    end

    test "a :managed deploy writes the target into the guest before enabling", %{agent: agent} do
      # `systemctl enable` will not link a unit into a target that does not
      # exist, and the guest agent only writes it during an unlock — so a VM on
      # an older agent would fail the enable. The deploy writes it too.
      ops = recording_ops(agent, spawn_result: {:ok, %{id: "svc-vm-1"}})

      assert {:ok, _} =
               Runtime.start("my-app", @release, @plan,
                 ops: ops,
                 gateway_domain: @domain,
                 spawn_opts: %{secrets_mode: :managed}
               )

      execs = for {:exec, _vm, cmd} <- events(agent), do: cmd

      write_idx =
        Enum.find_index(execs, &(&1 =~ "/etc/systemd/system/mjolnir-secrets.target"))

      enable_idx = Enum.find_index(execs, &(&1 =~ "systemctl enable"))

      assert write_idx, "the target unit was never written into the guest"
      assert enable_idx, "the app unit was never enabled"
      assert write_idx <= enable_idx, "the target must exist before the enable runs"
    end

    test "a plain deploy writes no target", %{agent: agent} do
      ops = recording_ops(agent, spawn_result: {:ok, %{id: "svc-vm-1"}})

      assert {:ok, _} =
               Runtime.start("my-app", @release, @plan, ops: ops, gateway_domain: @domain)

      execs = for {:exec, _vm, cmd} <- events(agent), do: cmd
      refute Enum.any?(execs, &(&1 =~ "mjolnir-secrets.target"))
    end
  end
end
