defmodule Mjolnir.Auth.KeycloakStrategy do
  @moduledoc """
  Deprecated name for `Mjolnir.Auth.JwksStrategy`.

  Keycloak (`connect.identikey.io`) is no longer the default issuer.
  The supervisor starts `JwksStrategy`. This module remains so a caller
  that still names it gets the same JWKS URL rules, including the old
  realm certs path when the issuer host is `connect.identikey.io`.
  """

  use JokenJwks.DefaultStrategyTemplate

  @deprecated "Use Mjolnir.Auth.JwksStrategy. Keycloak is not the default issuer."
  def init_opts(opts) do
    Mjolnir.Auth.JwksStrategy.init_opts(opts)
  end
end
