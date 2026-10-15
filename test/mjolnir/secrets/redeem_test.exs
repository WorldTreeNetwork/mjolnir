defmodule Mjolnir.Secrets.RedeemTest do
  use ExUnit.Case, async: false

  alias Mjolnir.Secrets.{Nonces, Redeem}

  test "a nonce is single use" do
    nonce = Nonces.issue()
    assert :ok = Nonces.consume(nonce)
    assert :error = Nonces.consume(nonce)
  end

  test "egress does not return a secret when the proof is missing" do
    assert {:error, :invalid_proof} =
             Redeem.egress(%{"url" => "https://example.com", "method" => "GET"})
  end

  test "the signing message binds nonce, token, and secret id" do
    assert Redeem.signing_message("abc", "dG9r", "github-pat") ==
             "mjolnir/redeem/v1\nabc\ndG9r\ngithub-pat"
  end
end
