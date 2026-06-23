defmodule Mjolnir.Sites.MultiSigTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Sites.{IdentiKey, MultiSig}

  describe "sign/2 + verify/3" do
    test "round-trips an ED25519 leg" do
      kp = IdentiKey.gen_keypair()
      bytes = "canonical-body"
      sig = MultiSig.sign(kp, bytes)

      assert %MultiSig{ed25519: ed, ml_dsa_87: nil} = sig
      assert byte_size(ed) == 64
      assert MultiSig.verify(sig, kp.ed25519_public, bytes)
    end

    test "verify fails on tampered bytes" do
      kp = IdentiKey.gen_keypair()
      sig = MultiSig.sign(kp, "authentic")
      refute MultiSig.verify(sig, kp.ed25519_public, "tampered")
    end

    test "verify fails for the wrong public key" do
      kp = IdentiKey.gen_keypair()
      other = IdentiKey.gen_keypair()
      sig = MultiSig.sign(kp, "body")
      refute MultiSig.verify(sig, other.ed25519_public, "body")
    end

    test "verify fails when the ed25519 leg is absent" do
      refute MultiSig.verify(%MultiSig{}, :crypto.strong_rand_bytes(32), "body")
    end
  end

  describe "to_field/1 wire shape (forward-compatible)" do
    test "encodes a populated leg as an object keyed by algorithm" do
      kp = IdentiKey.gen_keypair()
      sig = MultiSig.sign(kp, "body")
      field = MultiSig.to_field(sig)

      assert is_map(field)
      assert Map.keys(field) == ["ed25519"]
      assert {:ok, ^sig} = round_trip(field)
    end

    test "nil and empty signatures encode to nil (stable canonical bytes)" do
      assert MultiSig.to_field(nil) == nil
      assert MultiSig.to_field(%MultiSig{}) == nil
    end

    test "future ml_dsa_87 leg is additive — same object, extra key" do
      field = MultiSig.to_field(%MultiSig{ed25519: <<1, 2, 3>>, ml_dsa_87: <<9, 9>>})
      assert Map.keys(field) |> Enum.sort() == ["ed25519", "ml_dsa_87"]

      assert %MultiSig{ed25519: <<1, 2, 3>>, ml_dsa_87: <<9, 9>>} = MultiSig.from_field(field)
    end
  end

  describe "from_field/1 backward compatibility" do
    test "accepts the legacy bare base64-string shape" do
      raw = :crypto.strong_rand_bytes(64)
      legacy = Base.encode64(raw)
      assert %MultiSig{ed25519: ^raw, ml_dsa_87: nil} = MultiSig.from_field(legacy)
    end

    test "returns nil for nil and empty objects" do
      assert MultiSig.from_field(nil) == nil
      assert MultiSig.from_field(%{}) == nil
    end
  end

  defp round_trip(field) do
    # JSON-encode then decode the field (string keys preserved) and parse back.
    decoded = field |> Jason.encode!() |> Jason.decode!()
    {:ok, MultiSig.from_field(decoded)}
  end
end
