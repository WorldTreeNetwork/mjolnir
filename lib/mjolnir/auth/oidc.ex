defmodule Mjolnir.Auth.Oidc do
  @moduledoc """
  Talks to IdentiKey Connect (Keycloak) using the same public client
  `mj login` uses (`mjolnir-cli`).

  Authorization-code is blocked today: that client has no redirect_uri
  for `api.vm.worldtree.network`. Device-code + PKCE is already registered
  and is what the CLI uses, so the browser login uses it too.
  """

  @default_client_id "mjolnir-cli"
  @scopes "openid offline_access"

  @doc "Classify a token-endpoint JSON body. Pure, so tests do not hit Keycloak."
  @spec classify_token(map()) :: {:ok, String.t()} | :pending | :slow_down | {:error, term()}
  def classify_token(%{"access_token" => token}) when is_binary(token) and token != "" do
    {:ok, token}
  end

  def classify_token(%{"error" => "authorization_pending"}), do: :pending
  def classify_token(%{"error" => "slow_down"}), do: :slow_down
  def classify_token(%{"error" => err}), do: {:error, {:oidc_error, err}}
  def classify_token(other), do: {:error, {:oidc_unexpected, other}}

  @doc "PKCE S256 pair. Verifier is sent to the token endpoint; challenge to device-auth."
  @spec pkce() :: {String.t(), String.t()}
  def pkce do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  @spec client_id() :: String.t()
  def client_id do
    Application.get_env(:mjolnir, :auth, [])
    |> Keyword.get(:client_id, @default_client_id)
  end

  @spec issuer() :: String.t() | nil
  def issuer do
    Application.get_env(:mjolnir, :auth, [])[:issuer]
  end

  @spec start_device(String.t()) :: {:ok, map()} | {:error, term()}
  def start_device(code_challenge) when is_binary(code_challenge) do
    with {:ok, conf} <- discover(),
         {:ok, body} <-
           post_form(conf["device_authorization_endpoint"], %{
             "client_id" => client_id(),
             "scope" => @scopes,
             "code_challenge" => code_challenge,
             "code_challenge_method" => "S256"
           }) do
      case body do
        %{"device_code" => dc, "verification_uri" => uri} = b ->
          {:ok,
           %{
             device_code: dc,
             user_code: b["user_code"],
             verification_uri: uri,
             verification_uri_complete: b["verification_uri_complete"] || uri,
             interval: b["interval"] || 5,
             expires_in: b["expires_in"] || 600
           }}

        other ->
          {:error, {:device_auth_unexpected, other}}
      end
    end
  end

  @spec poll_token(String.t(), String.t()) ::
          {:ok, String.t()} | :pending | :slow_down | {:error, term()}
  def poll_token(device_code, code_verifier)
      when is_binary(device_code) and is_binary(code_verifier) do
    with {:ok, conf} <- discover(),
         {:ok, body} <-
           post_form(conf["token_endpoint"], %{
             "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
             "client_id" => client_id(),
             "device_code" => device_code,
             "code_verifier" => code_verifier
           }) do
      classify_token(body)
    end
  end

  defp discover do
    case issuer() do
      nil ->
        {:error, :no_issuer_configured}

      issuer ->
        url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

        case get_json(url) do
          {:ok, %{"device_authorization_endpoint" => _, "token_endpoint" => _} = conf} ->
            {:ok, conf}

          {:ok, other} ->
            {:error, {:discover_unexpected, other}}

          {:error, reason} ->
            {:error, {:discover_failed, reason}}
        end
    end
  end

  defp get_json(url) do
    http().({:get, url, nil})
  end

  defp post_form(url, form) when is_binary(url) do
    http().({:post, url, form})
  end

  defp http do
    Application.get_env(:mjolnir, :auth, [])
    |> Keyword.get(:oidc_http, &default_http/1)
  end

  defp default_http({:get, url, _}) do
    case Req.get(url, decode_body: true) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_http({:post, url, form}) do
    # Keycloak returns 400 with {"error":"authorization_pending"} while the
    # user is still on the login page. That is not a transport failure.
    case Req.post(url, form: form, decode_body: true) do
      {:ok, %{body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
