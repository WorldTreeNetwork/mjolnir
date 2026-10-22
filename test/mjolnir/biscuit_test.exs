defmodule Mjolnir.BiscuitTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Biscuit

  @empty Base.decode16!(
           "AF1349B9F5F9A1A6A0404DEA36DCC9499BCB25C9ADC112B7CC9A93CAE41F3262",
           case: :upper
         )

  test "blake3_hash empty-string known-answer vector" do
    assert Biscuit.blake3_hash("") == @empty
    assert Biscuit.blake3_hash("") == Biscuit.empty_vector()
  end

  test "holder fingerprint is algorithm-committing" do
    pub = :binary.copy(<<0x11>>, 32)
    fp = Biscuit.holder_fingerprint(pub)
    assert byte_size(fp) == 32
    refute fp == Biscuit.blake3_hash(pub)
  end

  test "secret commit is domain-separated and 32 bytes" do
    c = Biscuit.secret_commit("salt", "secret")
    assert byte_size(c) == 32
    refute c == Biscuit.blake3_hash("secret")
  end

  test "mint round-trip, holder check, and tamper" do
    %{private_hex: priv, public_hex: pub} = Biscuit.keypair()
    minted = Biscuit.mint(priv, "github-pat-ci", "redeem")
    assert :ok = Biscuit.parse(minted, pub)

    held = Biscuit.append_holder(minted, pub, "FP")
    assert :ok = Biscuit.authorize(held, pub, "FP", "github-pat-ci", "redeem", true)
    assert {:error, _} = Biscuit.authorize(held, pub, "FP", "github-pat-ci", "redeem", false)

    tampered = :binary.part(minted, 0, byte_size(minted) - 1) <> <<0>>
    assert {:error, _} = Biscuit.parse(tampered, pub)
  end
end
