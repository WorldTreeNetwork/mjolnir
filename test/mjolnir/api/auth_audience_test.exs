defmodule Mjolnir.API.AuthAudienceTest do
  use ExUnit.Case, async: true

  alias Mjolnir.API.Auth

  @clients ["mjolnir-cli", "mjolnir-term", "mjolnir"]

  test "the cli and browser client ids are both our audience" do
    assert :ok == Auth.audience_matches?("mjolnir-cli", @clients)
    assert :ok == Auth.audience_matches?("mjolnir-term", @clients)
    assert {:error, :audience} == Auth.audience_matches?("someone-else", @clients)
  end

  test "a single configured audience still has to match" do
    assert :ok == Auth.audience_matches?("mjolnir-cli", "mjolnir-cli")
    assert {:error, :audience} == Auth.audience_matches?("mjolnir-cli", "mjolnir")
  end

  test "a token that omits aud passes until require_audience" do
    assert :ok == Auth.audience_matches?(nil, @clients)
    assert {:error, :audience} == Auth.audience_matches?(nil, @clients, true)
  end

  test "an unset audience does not reject a named aud" do
    assert :ok == Auth.audience_matches?("mjolnir-cli", nil)
  end
end
