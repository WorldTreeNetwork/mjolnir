defmodule Mjolnir.Deploy.OwnerMintTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Deploy.Owner

  test "hex and base58 of the same bytes are one owner" do
    bytes = <<0xAB>> <> :binary.copy(<<0x10>>, 31)
    hex = Base.encode16(bytes, case: :lower)
    {:ok, from_hex} = Owner.mint_owner(hex)
    {:ok, from_b58} = Owner.mint_owner(Owner.encode(bytes))
    assert from_hex == from_b58
    assert from_b58 == Owner.encode(bytes)
  end

  test "refuses the edges" do
    bytes = <<0xAB>> <> :binary.copy(<<0x10>>, 31)
    canonical = Owner.encode(bytes)
    hex = Base.encode16(bytes, case: :lower)

    for bad <- [
          String.upcase(hex),
          hex <> "\n",
          " " <> canonical,
          canonical <> "\n",
          Owner.encode(:binary.copy(<<0xAB>>, 31)),
          "1" <> canonical
        ] do
      assert Owner.mint_owner(bad) == :error
    end
  end
end
