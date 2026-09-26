defmodule Mjolnir.Deploy.OwnerTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Deploy.Owner

  # 32 bytes of 0xAB. Canonical base58 (Bitcoin alphabet, leading zeros kept).
  @ab "CZ8YUVdk7znjrUmnb5n7kgySk9yRAsQDYmyCxzfSky9t"
  # SHA-256-sized fixture used by the old hex gate. Same 32 bytes as @duke_b58.
  @duke_hex "27060fd66283eb5c6c900bce5b364fa512fb4c718b6af18acc7720c424e08821"
  @duke_b58 "3dLGACrVKP67MtW4kwbG54JqBGS5nSb46uZVkJNueWKJ"
  # 0x00 followed by 31 bytes of 0x11. The leading zero is the character "1".
  @lead "1G6ShajrrdiRnD4mW22j8T5kXyKSvwXaC64S9VGSzFA"

  test "localhost may stamp a canonical base58 XID" do
    assert Owner.resolve("localhost", @ab) == {:ok, @ab}
    assert Owner.resolve("localhost", "  #{@ab}  ") == {:ok, @ab}
    assert Owner.resolve("localhost", @lead) == {:ok, @lead}
  end

  test "localhost fails closed when the header is missing or not a XID" do
    assert Owner.resolve("localhost", nil) == {:error, :owner_required}
    assert Owner.resolve("localhost", "localhost") == {:error, :invalid_owner}
    assert Owner.resolve("localhost", "not-an-owner") == {:error, :invalid_owner}
    assert Owner.resolve("localhost", @duke_hex) == {:error, :invalid_owner}
  end

  test "a 16-byte VM id is not an owner" do
    assert Owner.parse("2g") == :error
    assert {:error, :invalid_owner} = Owner.resolve("localhost", "2g")
  end

  test "a signed-in user cannot impersonate via the header" do
    assert Owner.resolve(@duke_b58, @ab) == {:ok, @duke_b58}
  end

  test "claim backfills nil and localhost, and rewrites legacy hex" do
    assert Owner.claim(nil, @duke_b58) == :ok
    assert Owner.claim("localhost", @duke_b58) == :ok
    assert Owner.claim(@duke_b58, @duke_b58) == :ok
    assert Owner.claim(@duke_hex, @duke_b58) == {:rewrite, @duke_b58}
  end

  test "claim rejects a different XID" do
    assert Owner.claim(@ab, @duke_b58) == {:error, :owner_mismatch}
    assert Owner.claim(@duke_hex, @ab) == {:error, :owner_mismatch}
    assert Owner.claim("not-an-owner", @ab) == {:error, :owner_mismatch}
  end

  test "stamp will not replace a base58 owner with localhost or hex" do
    assert Owner.stamp("localhost", @ab) == @ab
    assert Owner.stamp(nil, @ab) == @ab
    assert Owner.stamp(@duke_hex, @ab) == @ab
    assert Owner.stamp(@duke_b58, @duke_hex) == @duke_b58
    assert Owner.stamp(@ab, nil) == @ab
    assert Owner.stamp("user-1", nil) == "user-1"
    assert Owner.stamp("localhost", nil) == nil
  end

  test "legacy hex and base58 of the same XID are the same owner" do
    assert Owner.same?(@duke_hex, @duke_b58)
    assert Owner.same?(@duke_b58, @duke_hex)
    refute Owner.same?(@duke_hex, @ab)
    assert Owner.same?("alice", "alice")
    refute Owner.same?("alice", @duke_b58)
    refute Owner.same?(nil, @duke_b58)
  end
end
