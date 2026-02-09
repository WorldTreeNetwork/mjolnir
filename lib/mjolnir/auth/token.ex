defmodule Mjolnir.Auth.Token do
  @moduledoc """
  JWT verification using Joken + JokenJwks.

  When a Keycloak issuer is configured, tokens are verified against the JWKS.
  Validates `exp`, `iss`, and `aud` claims.
  """

  use Joken.Config

  add_hook(JokenJwks, strategy: Mjolnir.Auth.KeycloakStrategy)

  @impl true
  def token_config do
    auth_config = Application.get_env(:mjolnir, :auth, [])
    issuer = Keyword.get(auth_config, :issuer)
    audience = Keyword.get(auth_config, :audience, "mjolnir")

    default_claims(skip: [:aud, :iss])
    |> add_claim("iss", nil, &(&1 == issuer))
    |> add_claim("aud", nil, &validate_audience(&1, audience))
  end

  defp validate_audience(aud, expected) when is_binary(aud), do: aud == expected
  defp validate_audience(aud, expected) when is_list(aud), do: expected in aud
  defp validate_audience(_, _), do: false

  @doc """
  Verify and validate a bearer token.

  Uses JWKS when an issuer is configured, otherwise returns an error.
  Returns `{:ok, claims}` or `{:error, reason}`.
  """
  def verify_token(token) do
    auth_config = Application.get_env(:mjolnir, :auth, [])

    if Keyword.get(auth_config, :issuer) do
      # Uses the generated verify_and_validate/1 which includes the JokenJwks hook
      verify_and_validate(token)
    else
      {:error, :no_issuer_configured}
    end
  end
end
