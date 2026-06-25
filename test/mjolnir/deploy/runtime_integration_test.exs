defmodule Mjolnir.Deploy.RuntimeIntegrationTest do
  @moduledoc """
  Server-gated integration test for Deploy.Runtime (mjolnir-gge.1.5).

  Boots a release snapshot as a service VM, installs the ad-hoc systemd unit over
  vsock, and verifies systemd actually brings the unit up. Uses a shell-only
  service (no Node/Python needed) and a snapshot stood up inline, so it does not
  depend on the Builder or a real app toolchain.

  Like the Builder integration test, the committed ExUnit form needs a populated
  isolated test btrfs root (see mjolnir-gge.1.8); on the live server this scenario
  was instead driven inside the running node via `mjolnir rpc`.
  """
  use Mjolnir.VMCase

  alias Mjolnir.Deploy.Runtime

  @moduletag :integration
  @moduletag :snapshot
  @moduletag timeout: 600_000

  defp base_image, do: Application.get_env(:mjolnir, :default_base_image, "ubuntu-24.04")

  @tag :cloud_hypervisor
  test "boots a release snapshot as a service VM and systemd brings the unit up" do
    # Stand up a throwaway "release" snapshot: boot the base, drop a marker, snapshot.
    {:ok, builder_vm} = Mjolnir.VM.spawn(%{base_image: base_image()})
    {:ok, _} = Mjolnir.VM.exec(builder_vm.id, "echo built > /root/built.txt")

    release = "deploy-rt-itest-#{System.os_time(:second)}"
    {:ok, _} = Mjolnir.VM.snapshot(builder_vm.id, release)
    :ok = Mjolnir.VM.stop(builder_vm.id)
    on_exit(fn -> Mjolnir.BTRFS.delete_snapshot(release) end)

    app = "rt-itest"
    log = "/var/log/#{app}.log"

    plan = %{
      start_command: "while true; do echo alive >> #{log}; sleep 2; done",
      port: 3000
    }

    on_exit(fn -> Mjolnir.Deploy.Registry.delete(app) end)

    assert {:ok, r} = Runtime.start(app, release, plan, ticket_timeout: 60_000)
    on_exit(fn -> Mjolnir.VM.stop(r.service_vm_id) end)

    # URL is the z32 ticket + port under the gateway domain.
    assert r.url =~ ~r{^https://.+-3000\.}
    assert r.release_snapshot == release

    # The release's baked-in file is present (proves we booted from the snapshot).
    assert {:ok, built} = Mjolnir.VM.exec(r.service_vm_id, "cat /root/built.txt")
    assert String.trim(built) == "built"

    # systemd brought the ad-hoc unit up.
    assert {:ok, active} = Mjolnir.VM.exec(r.service_vm_id, "systemctl is-active #{app}.service")
    assert String.trim(active) == "active"

    # The service actually ran (its heartbeat log exists and grows).
    assert {:ok, _} = Mjolnir.VM.exec(r.service_vm_id, "test -f #{log}")

    # Registered.
    assert {:ok, entry} = Mjolnir.Deploy.Registry.get(app)
    assert entry.service_vm_id == r.service_vm_id
    assert entry.url == r.url
  end
end
