defmodule Mjolnir.API.Views do
  @moduledoc """
  JSON serialization for API responses.
  """

  @doc """
  Serialize a VM struct to a JSON-safe map.
  """
  def vm_json(%Mjolnir.VM{} = vm) do
    %{
      id: vm.id,
      state: vm.state,
      config: config_json(vm.config)
    }
  end

  defp config_json(nil), do: nil

  defp config_json(config) do
    %{
      base_image: config.base_image,
      vcpu_count: config.vcpu_count,
      mem_size_mib: config.mem_size_mib
    }
  end
end
