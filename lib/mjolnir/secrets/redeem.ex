defmodule Mjolnir.Secrets.Redeem do
  @moduledoc """
  Holder-bound redeem of a foreign secret, and the egress call that
  uses the secret without returning it.

  The token is a Biscuit `right(<secret_id>, "redeem")`. Possession of
  the bytes is not enough. The caller signs

      mjolnir/redeem/v1\\n<nonce>\\n<biscuit-base64>\\n<secret_id>

  with the Ed25519 key named by the holder check. The verifier injects
  `holder(<fingerprint>)` and only then evaluates the token.

  Copy-out (`redeem/1`) returns the bytes to that holder. `egress/1`
  performs the upstream request and returns the response. The secret
  is not in that response and is not logged.

  The secret bytes live in `SecretStore` under `put_opaque("secrets",
  id, "value", bytes)`.
  """

  alias Mjolnir.Biscuit
  alias Mjolnir.Secrets.Nonces
  alias Mjolnir.SecretStore

  @domain "mjolnir/redeem/v1"
  @max_body 1_048_576

  @spec challenge() :: String.t()
  def challenge, do: Nonces.issue()

  @spec redeem(map()) :: {:ok, binary()} | {:error, atom()}
  def redeem(params) when is_map(params) do
    with {:ok, secret} <- prove(params) do
      {:ok, secret}
    end
  end

  @spec egress(map()) :: {:ok, integer(), binary()} | {:error, atom()}
  def egress(params) when is_map(params) do
    with {:ok, secret} <- prove(params),
         {:ok, method, url} <- request(params),
         :ok <- allow_url(url) do
      call_upstream(method, url, secret)
    end
  end

  defp prove(params) do
    secret_id = params["secret_id"]
    nonce = params["nonce"]
    biscuit_b64 = params["biscuit"]
    pub_b64 = params["public_key"]
    sig_b64 = params["signature"]

    with true <- is_binary(secret_id) and secret_id != "",
         true <- is_binary(nonce),
         :ok <- Nonces.consume(nonce),
         {:ok, biscuit} <- decode64(biscuit_b64),
         {:ok, public} <- decode64(pub_b64),
         {:ok, signature} <- decode64(sig_b64),
         true <- byte_size(public) == 32 and byte_size(signature) == 64,
         message = signing_message(nonce, biscuit_b64, secret_id),
         true <- :crypto.verify(:eddsa, :none, message, signature, public),
         {:ok, fp} <- holder_fp(public),
         :ok <- authorize(biscuit, fp, secret_id),
         {:ok, secret} <- SecretStore.get_opaque("secrets", secret_id, "value") do
      {:ok, secret}
    else
      false -> {:error, :invalid_proof}
      :error -> {:error, :invalid_proof}
      :not_found -> {:error, :not_found}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _} -> {:error, :invalid_proof}
    end
  end

  @doc false
  def signing_message(nonce, biscuit_b64, secret_id) do
    @domain <> "\n" <> nonce <> "\n" <> biscuit_b64 <> "\n" <> secret_id
  end

  defp request(params) do
    method = params["method"] |> to_string() |> String.upcase()
    url = params["url"]

    if method in ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"] and is_binary(url) do
      {:ok, method, url}
    else
      {:error, :bad_request}
    end
  end

  defp allow_url(url) do
    hosts = Application.get_env(:mjolnir, :egress_allow_hosts, [])

    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["https", "http"] and is_binary(host) ->
        if host in hosts, do: :ok, else: {:error, :host_not_allowed}

      _ ->
        {:error, :host_not_allowed}
    end
  end

  defp call_upstream(method, url, secret) do
    case Req.request(
           method: method,
           url: url,
           redirect: false,
           headers: [{"authorization", "Bearer " <> secret}],
           decode_body: false,
           retry: false
         ) do
      {:ok, %{status: status, body: body}} ->
        body =
          case body do
            bin when is_binary(bin) -> bin
            other -> inspect(other)
          end

        {:ok, status, binary_part(body, 0, min(byte_size(body), @max_body))}

      {:error, _} ->
        {:error, :upstream_failed}
    end
  end

  defp authorize(biscuit, fp, secret_id) do
    case Application.get_env(:mjolnir, :biscuit_public_hex) do
      hex when is_binary(hex) and hex != "" ->
        # A token with no holder check authorizes even when the verifier
        # injects nothing. Redeem requires the check: the uninjected
        # call must fail, and the injected call must succeed.
        case Biscuit.authorize(biscuit, hex, fp, secret_id, "redeem", false) do
          :ok ->
            {:error, :holder_required}

          _ ->
            Biscuit.authorize(biscuit, hex, fp, secret_id, "redeem", true)
        end

      _ ->
        {:error, :biscuit_unconfigured}
    end
  rescue
    _ -> {:error, :biscuit_unavailable}
  end

  defp holder_fp(public) do
    try do
      {:ok, Base.encode16(Biscuit.holder_fingerprint(public), case: :lower)}
    rescue
      _ -> {:error, :biscuit_unavailable}
    end
  end

  defp decode64(value) when is_binary(value) do
    case Base.decode64(value, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> Base.decode64(value)
    end
  end

  defp decode64(_), do: :error
end
