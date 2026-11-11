defmodule Mjolnir.Aie.Allowlist do
  @moduledoc """
  Operator-held allowlist of VM ids that may publish or mint AIE offers.

  Config:
  - `:aie_offering_vm_ids` — list of VM ids permitted to offer host capacity
  - `:aie_vm_identikeys` — map of `vm_id =>` IdentiKey fingerprint (keyspace fp)
  """

  @spec member?(String.t()) :: boolean()
  def member?(vm_id) when is_binary(vm_id) do
    vm_id in offering_vm_ids()
  end

  @spec offering_vm_ids() :: [String.t()]
  def offering_vm_ids do
    case Application.get_env(:mjolnir, :aie_offering_vm_ids, []) do
      ids when is_list(ids) -> Enum.filter(ids, &is_binary/1)
      _ -> []
    end
  end

  @spec identikey_for(String.t()) :: {:ok, String.t()} | {:error, :vm_identikey_unknown}
  def identikey_for(vm_id) when is_binary(vm_id) do
    map = Application.get_env(:mjolnir, :aie_vm_identikeys, %{})

    case is_map(map) && Map.get(map, vm_id) do
      fp when is_binary(fp) and fp != "" -> {:ok, fp}
      _ -> {:error, :vm_identikey_unknown}
    end
  end
end
