defmodule Mjolnir.Auth.JwksStrategyTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Auth.JwksStrategy

  test "default jwks url is the issuer well-known document" do
    opts = JwksStrategy.init_opts(issuer: "https://auth.identikey.me")

    assert opts[:jwks_url] == "https://auth.identikey.me/.well-known/jwks.json"
    assert opts[:http_adapter] == Tesla.Adapter.Mint
  end

  test "a trailing slash is not part of the jwks url" do
    opts = JwksStrategy.init_opts(issuer: "https://auth.identikey.me/")

    assert opts[:jwks_url] == "https://auth.identikey.me/.well-known/jwks.json"
  end

  test "deprecated keycloak issuer still uses the realm certs url" do
    opts = JwksStrategy.init_opts(issuer: "https://connect.identikey.io/realms/identikey/")

    assert opts[:jwks_url] ==
             "https://connect.identikey.io/realms/identikey/protocol/openid-connect/certs"
  end

  test "an explicit jwks_url wins over the issuer default" do
    opts =
      JwksStrategy.init_opts(
        issuer: "https://auth.identikey.me",
        jwks_url: "https://example.test/jwks"
      )

    assert opts[:jwks_url] == "https://example.test/jwks"
  end
end
