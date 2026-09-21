defmodule Mjolnir.Sites.FallbackPolicyTest do
  use ExUnit.Case, async: false

  alias Mjolnir.SecretStore
  alias Mjolnir.Sites.{FallbackPolicy, IdentiKey}

  test "serializes, parses, and verifies the separate signed policy envelope" do
    keypair = IdentiKey.gen_keypair()
    fp = IdentiKey.fingerprint(keypair)
    site = "fallback-policy-test"

    on_exit(fn -> File.rm_rf(Path.join(SecretStore.root(), fp)) end)

    :ok =
      SecretStore.put(
        fp,
        "identity/pubkey",
        Jason.encode!(%{"pubkey" => Base.encode64(keypair.ed25519_public)})
      )

    unsigned = %FallbackPolicy{
      fallback: :index,
      sequence: 42,
      identikey_fp: fp,
      site_name: site,
      created_at: DateTime.utc_now() |> DateTime.truncate(:second),
      signature: nil
    }

    signed = %{
      unsigned
      | signature: IdentiKey.sign(keypair, FallbackPolicy.canonical_signing_bytes(unsigned))
    }

    bytes = FallbackPolicy.serialize(signed)

    assert {:ok, parsed} = FallbackPolicy.parse(bytes)
    assert parsed.fallback == :index
    assert parsed.sequence == 42
    assert :ok = FallbackPolicy.verify(parsed)
  end

  test "rejects values outside the three-value policy" do
    bytes =
      Jason.encode!(%{
        "fallback" => true,
        "sequence" => 1,
        "identikey_fp" => "fp",
        "site_name" => "site",
        "created_at" => "2026-09-21T00:00:00Z",
        "signature" => nil
      })

    assert {:error, :bad_fallback_policy} = FallbackPolicy.parse(bytes)
  end
end
