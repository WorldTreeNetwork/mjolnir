defmodule Mjolnir.Sites.IdentiKeyTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias Mjolnir.Sites.IdentiKey

  describe "gen_keypair/0" do
    test "returns a map with 32-byte public and secret keys" do
      kp = IdentiKey.gen_keypair()
      assert is_map(kp)
      assert is_binary(kp.ed25519_public)
      assert is_binary(kp.ed25519_secret)
      assert byte_size(kp.ed25519_public) == 32
      assert byte_size(kp.ed25519_secret) == 32
    end

    test "generates distinct keypairs on each call" do
      kp1 = IdentiKey.gen_keypair()
      kp2 = IdentiKey.gen_keypair()
      refute kp1.ed25519_public == kp2.ed25519_public
      refute kp1.ed25519_secret == kp2.ed25519_secret
    end
  end

  describe "sign/2 + verify/3" do
    test "round-trip: sign then verify returns true" do
      kp = IdentiKey.gen_keypair()
      msg = "hello, identikey"
      sig = IdentiKey.sign(kp, msg)
      assert is_binary(sig)
      assert byte_size(sig) == 64
      assert IdentiKey.verify(kp.ed25519_public, msg, sig)
    end

    test "verify returns false for modified message" do
      kp = IdentiKey.gen_keypair()
      msg = "authentic message"
      sig = IdentiKey.sign(kp, msg)
      refute IdentiKey.verify(kp.ed25519_public, "tampered message", sig)
    end

    test "verify returns false for wrong public key" do
      kp1 = IdentiKey.gen_keypair()
      kp2 = IdentiKey.gen_keypair()
      msg = "message"
      sig = IdentiKey.sign(kp1, msg)
      refute IdentiKey.verify(kp2.ed25519_public, msg, sig)
    end

    test "verify returns false for modified signature" do
      kp = IdentiKey.gen_keypair()
      msg = "message"
      sig = IdentiKey.sign(kp, msg)
      <<first, rest::binary>> = sig
      bad_sig = <<bxor(first, 0xFF), rest::binary>>
      refute IdentiKey.verify(kp.ed25519_public, msg, bad_sig)
    end

    test "sign produces deterministic output for same key+message" do
      kp = IdentiKey.gen_keypair()
      msg = "deterministic"
      sig1 = IdentiKey.sign(kp, msg)
      sig2 = IdentiKey.sign(kp, msg)
      assert sig1 == sig2
    end
  end

  describe "fingerprint/1" do
    test "is deterministic for the same keypair" do
      kp = IdentiKey.gen_keypair()
      fp1 = IdentiKey.fingerprint(kp)
      fp2 = IdentiKey.fingerprint(kp)
      assert fp1 == fp2
    end

    test "accepts raw public key bytes" do
      kp = IdentiKey.gen_keypair()
      fp_from_kp = IdentiKey.fingerprint(kp)
      fp_from_pub = IdentiKey.fingerprint(kp.ed25519_public)
      assert fp_from_kp == fp_from_pub
    end

    test "is non-empty string" do
      kp = IdentiKey.gen_keypair()
      fp = IdentiKey.fingerprint(kp)
      assert is_binary(fp)
      assert byte_size(fp) > 0
    end

    test "differs between keypairs" do
      kp1 = IdentiKey.gen_keypair()
      kp2 = IdentiKey.gen_keypair()
      refute IdentiKey.fingerprint(kp1) == IdentiKey.fingerprint(kp2)
    end
  end

  describe "keypair_to_json/1 + keypair_from_json/1" do
    test "round-trips a keypair through JSON" do
      kp = IdentiKey.gen_keypair()
      json = IdentiKey.keypair_to_json(kp)
      assert is_binary(json)
      assert {:ok, kp2} = IdentiKey.keypair_from_json(json)
      assert kp2.ed25519_public == kp.ed25519_public
      assert kp2.ed25519_secret == kp.ed25519_secret
    end

    test "fingerprint is stable across JSON round-trip" do
      kp = IdentiKey.gen_keypair()
      fp_before = IdentiKey.fingerprint(kp)
      {:ok, kp2} = kp |> IdentiKey.keypair_to_json() |> IdentiKey.keypair_from_json()
      assert IdentiKey.fingerprint(kp2) == fp_before
    end

    test "keypair_from_json returns error for bad JSON" do
      assert {:error, _} = IdentiKey.keypair_from_json("not json")
    end

    test "keypair_from_json returns error for missing key" do
      json = Jason.encode!(%{"ed25519_public" => Base.encode64("x")})
      assert {:error, :missing_key} = IdentiKey.keypair_from_json(json)
    end
  end
end
