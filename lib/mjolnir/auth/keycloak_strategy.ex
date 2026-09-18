defmodule Mjolnir.Auth.KeycloakStrategy do
  @moduledoc """
  JokenJWKS strategy for fetching and caching JWKS from a Keycloak issuer.

  Only started when `:issuer` is configured in `:mjolnir, :auth`.
  Fetches keys from `{issuer}/protocol/openid-connect/certs`.

  ## Why the adapter is pinned here

  `JokenJwks.HttpFetcher` defaults to `Tesla.Adapter.Hackney`, and hackney's
  only CVE-free line (4.x) is forbidden by joken_jwks 1.7's own optional
  `~> 1.18` constraint — so hackney was dropped from the project entirely
  (mjolnir-ctv). This is the caller that made hackney reachable at all: it is
  not called from Mjolnir code, so a grep for "hackney" finds nothing and the
  breakage only shows up as a supervisor crash at boot.

  `Tesla.Adapter.Mint` replaces it. Mint is already in the tree under Req, and
  it verifies certificates by default via CAStore — which is the property
  joken_jwks's docs cite as the reason they chose hackney, so it must not be
  traded away for an adapter (e.g. `:httpc`) that defaults to not verifying.
  """

  use JokenJwks.DefaultStrategyTemplate

  def init_opts(opts) do
    issuer = Keyword.fetch!(opts, :issuer) |> String.trim_trailing("/")

    jwks_url =
      Keyword.get(opts, :jwks_url) ||
        if String.contains?(issuer, "connect.identikey.io") do
          issuer <> "/protocol/openid-connect/certs"
        else
          issuer <> "/.well-known/jwks.json"
        end

    opts
    |> Keyword.put(:jwks_url, jwks_url)
    |> Keyword.put_new(:http_adapter, Tesla.Adapter.Mint)
  end
end
