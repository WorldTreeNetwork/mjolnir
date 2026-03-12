defmodule Mjolnir.API.Views do
  @moduledoc """
  JSON serialization helpers for VM data.
  """

  @doc """
  Full VM representation including connection details.
  """
  @gateway_domain Application.compile_env(:mjolnir, :gateway_domain, "vm.worldtree.network")

  def render_vm(vm) do
    %{
      id: vm.id,
      state: vm.state,
      owner_id: vm.owner_id,
      hypervisor: hypervisor_name(vm.hypervisor),
      guest_ip: get_in_net(vm, :guest_ip),
      pty_ready: vm.pty_ready || false,
      ticket: vm.ticket,
      iroh_addr: vm.iroh_json,
      enable_iroh: vm.enable_iroh,
      web_url: web_url(vm),
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
      owner_id: vm.owner_id,
      hypervisor: hypervisor_name(vm.hypervisor),
      guest_ip: get_in_net(vm, :guest_ip),
      pty_ready: vm.pty_ready || false,
      ticket: vm.ticket,
      web_url: web_url(vm)
    }
  end

  defp get_in_net(vm, key) do
    case vm.net_config do
      %{^key => val} -> val
      _ -> nil
    end
  end

  defp hypervisor_name(nil), do: nil

  defp hypervisor_name(hypervisor_module) when is_atom(hypervisor_module) do
    hypervisor_module.process_name()
  end

  defp web_url(%{enable_iroh: true, ticket: ticket}) when is_binary(ticket) do
    "https://#{ticket}.#{@gateway_domain}"
  end

  defp web_url(_), do: nil

  defp render_config(nil), do: nil

  defp render_config(config) do
    %{
      vcpu_count: config.vcpu_count,
      mem_size_mib: config.mem_size_mib,
      base_image: config.base_image,
      snapshot: config.snapshot
    }
  end
end
