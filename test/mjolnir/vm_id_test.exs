defmodule Mjolnir.VmIdTest do
  use ExUnit.Case, async: true

  alias Mjolnir.VmId

  @uuid "01234567-89ab-cdef-0123-456789abcdef"
  @b58 "99dn6s7bZoVpjzYciVNgN"

  test "uuid and base58 are the same 16 bytes" do
    assert {:ok, @b58} = VmId.canonicalize(@uuid)
    assert {:ok, @b58} = VmId.canonicalize(@b58)
    assert VmId.storage_id(@uuid) == @b58
    assert VmId.encode(Base.decode16!(String.replace(@uuid, "-", ""), case: :lower)) == @b58
  end

  test "sixteen zero bytes are sixteen ones" do
    assert VmId.encode(<<0::128>>) == "1111111111111111"
    assert {:ok, <<0::128>>} = VmId.decode("1111111111111111")
  end

  test "generate is base58 of a uuid4" do
    id = VmId.generate()
    assert {:ok, ^id} = VmId.canonicalize(id)
    refute String.contains?(id, "-")
    assert byte_size(id) in 21..22
  end

  test "rejects an account-sized id and garbage" do
    xid = VmId.encode(:crypto.strong_rand_bytes(32))
    assert :error = VmId.canonicalize(xid)
    assert :error = VmId.canonicalize(String.duplicate("ab", 32))
    assert :error = VmId.canonicalize("not-a-vm")
    assert VmId.storage_id("not-a-vm") == "not-a-vm"
  end
end
