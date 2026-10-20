defmodule Mjolnir.VmmScopeTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Hypervisor.CloudHypervisor
  alias Mjolnir.VmmScope

  @vm_id "uepi-scope-test"

  test "stop targets the per-VM scope and not the orchestrator service" do
    {cmd, args} = VmmScope.stop_command(@vm_id)

    assert cmd == "systemctl"
    assert "mjolnir-#{@vm_id}.scope" in args
    assert VmmScope.slice() == "mjolnir-vms.slice"
    refute Enum.any?([cmd | args], &String.contains?(&1, "mjolnir.service"))
  end

  test "detached launch wraps cloud-hypervisor in the sibling slice" do
    prev = Application.get_env(:mjolnir, :detach_vmm)
    Application.put_env(:mjolnir, :detach_vmm, true)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:mjolnir, :detach_vmm, prev),
        else: Application.delete_env(:mjolnir, :detach_vmm)
    end)

    {exe, args} =
      CloudHypervisor.launch_spec(%{
        socket_path: "/tmp/mjolnir/#{@vm_id}.sock",
        vm_id: @vm_id
      })

    assert exe == "systemd-run"
    assert "--slice=mjolnir-vms.slice" in args
    assert "--unit=mjolnir-#{@vm_id}.scope" in args
    assert "--" in args
    assert "--api-socket" in args
    refute Enum.any?(args, &String.contains?(&1, "mjolnir.service"))
  end

  test "the default launch is still a direct cloud-hypervisor exec" do
    prev = Application.get_env(:mjolnir, :detach_vmm)
    Application.delete_env(:mjolnir, :detach_vmm)

    on_exit(fn ->
      if prev, do: Application.put_env(:mjolnir, :detach_vmm, prev)
    end)

    {exe, args} =
      CloudHypervisor.launch_spec(%{
        socket_path: "/tmp/mjolnir/#{@vm_id}.sock",
        vm_id: @vm_id
      })

    assert exe =~ "cloud-hypervisor"
    assert "--api-socket" in args
    refute exe == "systemd-run"
  end
end
