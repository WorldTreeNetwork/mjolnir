defmodule Mjolnir.Vsock do
  @moduledoc """
  Vsock helpers shared by spawn and memory-snapshot thaw.

  CID 0–2 are reserved by the kernel; `0xFFFFFFFF` is `VMADDR_CID_ANY`.
  Everything we allocate sits in `[3, 0xFFFFFFFF)`.
  """

  @doc """
  Deterministic vsock CID from a VM id.

  First 4 bytes of `MD5(vm_id)`, mapped into `[3, 0xFFFFFFFF)`. Same formula
  spawn has always used — extracted so a remapped thaw can mint a CID for a
  new identity without going through `Mjolnir.VM`.
  """
  @spec cid(String.t()) :: pos_integer()
  def cid(vm_id) when is_binary(vm_id) do
    <<cid_raw::unsigned-32, _rest::binary>> = :crypto.hash(:md5, vm_id)
    rem(cid_raw, 0xFFFFFFFF - 3) + 3
  end
end
