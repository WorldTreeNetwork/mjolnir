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
      iroh_node_id: vm.iroh_node_id,
      iroh_ticket: vm.iroh_ticket
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
      iroh_node_id: vm.iroh_node_id
    }
  end

  defp get_in_net(vm, key) do
    case vm.net_config do
      %{^key => val} -> val
      _ -> nil
    end
  end
end
