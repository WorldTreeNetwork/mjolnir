defmodule Mjolnir.API.Views do
  @moduledoc """
  JSON serialization helpers for VM data.
  """

  @doc """
  Full VM representation including connection details.
  """
  def render_vm(vm) do
    %{
      id: vm.id,
      state: vm.state,
      guest_ip: get_in_net(vm, :guest_ip),
      shell_ready: vm.shell_ready || false,
      ticket: vm.ticket,
      iroh_addr: vm.iroh_json,
      enable_iroh: vm.enable_iroh,
      config: render_config(vm.config),
      boot_time: vm.boot_time
    }
  end

  @doc """
  Summary VM representation for list endpoints.
  """
  def render_vm_summary(vm) do
    %{
      id: vm.id,
      state: vm.state,
      guest_ip: get_in_net(vm, :guest_ip),
      shell_ready: vm.shell_ready || false,
      ticket: vm.ticket
    }
  end

  defp get_in_net(vm, key) do
    case vm.net_config do
      %{^key => val} -> val
      _ -> nil
    end
  end

  defp render_config(nil), do: nil

  defp render_config(config) do
    %{
      vcpu_count: config.vcpu_count,
      mem_size_mib: config.mem_size_mib,
      base_image: config.base_image,
      snapshot: config.snapshot,
      rootfs_size_mb: config.rootfs_size_mb
    }
  end
end
