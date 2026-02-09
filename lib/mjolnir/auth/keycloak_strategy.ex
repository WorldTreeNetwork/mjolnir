defmodule Mjolnir.Auth.KeycloakStrategy do
  @moduledoc """
  JokenJWKS strategy for fetching and caching JWKS from a Keycloak issuer.

  Only started when `:issuer` is configured in `:mjolnir, :auth`.
  Fetches keys from `{issuer}/protocol/openid-connect/certs`.
  """

  use JokenJwks.DefaultStrategyTemplate

  def init_opts(opts) do
    issuer = Keyword.fetch!(opts, :issuer)
    jwks_url = String.trim_trailing(issuer, "/") <> "/protocol/openid-connect/certs"
    Keyword.put(opts, :jwks_url, jwks_url)
  end
end
