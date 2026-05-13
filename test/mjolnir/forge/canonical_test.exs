defmodule Mjolnir.Forge.CanonicalTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Forge.Canonical

  test "encodes a flat map with sorted keys, regardless of insertion order" do
    a = %{b: 1, a: 2, c: 3}
    b = %{a: 2, b: 1, c: 3}
    c = %{c: 3, a: 2, b: 1}

    assert Canonical.encode(a) == Canonical.encode(b)
    assert Canonical.encode(b) == Canonical.encode(c)
    # Concrete shape — keys sorted alphabetically.
    assert Canonical.encode(a) == ~s({"a":2,"b":1,"c":3})
  end

  test "preserves list order" do
    assert Canonical.encode([3, 1, 2]) == "[3,1,2]"
    assert Canonical.encode([1, 2, 3]) == "[1,2,3]"
    refute Canonical.encode([3, 1, 2]) == Canonical.encode([1, 2, 3])
  end

  test "stringifies atom keys and atom values" do
    assert Canonical.encode(%{key: :value}) == ~s({"key":"value"})
  end

  test "nested maps sort recursively" do
    a = %{outer: %{z: 1, a: 2}}
    b = %{outer: %{a: 2, z: 1}}
    assert Canonical.encode(a) == Canonical.encode(b)
  end

  test "binaries pass through" do
    assert Canonical.encode("hello") == ~s("hello")
  end

  test "hash is stable across encodings of the same content" do
    a = %{b: 1, a: 2}
    b = %{a: 2, b: 1}
    assert Canonical.hash(a) == Canonical.hash(b)
  end

  test "hash differs when content differs" do
    assert Canonical.hash(%{a: 1}) != Canonical.hash(%{a: 2})
  end

  test "hash_bytes computes SHA-256 over arbitrary binary" do
    assert byte_size(Canonical.hash_bytes("hi")) == 32
    assert Canonical.hash_bytes("hi") != Canonical.hash_bytes("bye")
  end
end
