defmodule Mjolnir.Secrets.Redeem do
  @moduledoc """
  Holder-bound redeem of a foreign secret, and the egress call that
  uses the secret without returning it.

  The token is a Biscuit `right(<secret_id>, "redeem")`. Possession of
  the bytes is not enough. The caller signs a NUL-terminated
  `mjolnir/redeem/v1` domain followed by eight uint32 big-endian
  length-prefixed fields: biscuit base64, nonce, audience, method,
  resource, Blake3 of the decoded body, secret id, and idempotency key.
  The verifier injects `holder(<fingerprint>)` before evaluating the token.

  Copy-out (`redeem/1`) returns the bytes and stored salt to that holder. `egress/1`
  performs the upstream request and returns the response. The secret
  is not in that response and is not logged.

  The secret bytes and JSON metadata are read from `SecretStore` opaque
  objects under `secrets/<id>/value` and `secrets/<id>/meta`. The metadata
  salt and commitment must match the value before either operation proceeds.
  """

  alias Mjolnir.Biscuit
  alias Mjolnir.Secrets.Nonces
  alias Mjolnir.SecretStore

  @domain "mjolnir/redeem/v1\0"
  @max_body 1_048_576

  @spec challenge() :: String.t()
  def challenge, do: Nonces.issue()

  @spec redeem(map()) :: {:ok, binary(), binary()} | {:error, atom()}
  def redeem(params) when is_map(params) do
    with {:ok, secret, salt, body} <- prove(params),
         true <- params["method"] == "REDEEM" and params["resource"] == params["secret_id"],
         true <- body == <<>> do
      {:ok, secret, salt}
    else
      false -> {:error, :invalid_proof}
      error -> error
    end
  end

  @spec egress(map()) :: {:ok, integer(), binary()} | {:error, atom()}
  def egress(params) when is_map(params) do
    with {:ok, secret, _salt, body} <- prove(params),
         {:ok, method, url} <- request(params),
         :ok <- allow_url(url) do
      call_upstream(method, url, secret, body, Map.get(params, "idempotency_key", ""))
    end
  end

  defp prove(params) do
    secret_id = params["secret_id"]
    nonce = params["nonce"]
    biscuit_b64 = params["biscuit"]
    pub_b64 = params["public_key"]
    sig_b64 = params["signature"]

    with true <- valid_nonce?(nonce),
         :ok <- Nonces.consume(nonce),
         true <- valid_fields?(params),
         {:ok, body} <- decode64(Map.get(params, "body_b64", "")),
         {:ok, biscuit} <- decode64(biscuit_b64),
         {:ok, public} <- decode64(pub_b64),
         {:ok, signature} <- decode64(sig_b64),
         true <- byte_size(public) == 32 and byte_size(signature) == 64,
         message = frame(nonce, biscuit_b64, params, body),
         true <- :crypto.verify(:eddsa, :none, message, signature, [public, :ed25519]),
         {:ok, fp} <- holder_fp(public),
         :ok <- authorize(biscuit, fp, secret_id),
         {:ok, secret, salt} <- read_record(secret_id) do
      {:ok, secret, salt, body}
    else
      false -> {:error, :invalid_proof}
      :error -> {:error, :invalid_proof}
      :not_found -> {:error, :not_found}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _} -> {:error, :invalid_proof}
    end
  rescue
    _ -> {:error, :biscuit_unavailable}
  end

  defp read_record(secret_id) do
    with {:ok, value} <- SecretStore.get_opaque("secrets", secret_id, "value"),
         {:ok, meta} <- SecretStore.get_opaque("secrets", secret_id, "meta"),
         true <- String.valid?(meta),
         {:ok, %{"salt_b64" => salt_b64, "commitment_hex" => hex}} <- Jason.decode(meta),
         {:ok, salt} <- decode64(salt_b64),
         true <- byte_size(salt) == 32,
         true <- is_binary(hex) and byte_size(hex) == 64,
         {:ok, commitment} <- Base.decode16(hex, case: :lower),
         true <- Biscuit.secret_commit(salt, value) == commitment do
      {:ok, value, salt}
    else
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :biscuit_unavailable}
  end

  @doc false
  def signing_message(nonce, biscuit_b64, params) when is_map(params) do
    {:ok, body} = decode64(Map.get(params, "body_b64", ""))
    frame(nonce, biscuit_b64, params, body)
  end

  defp frame(nonce, biscuit_b64, params, body) do
    fields = [
      biscuit_b64,
      nonce,
      params["audience"],
      params["method"],
      params["resource"],
      Biscuit.blake3_hash(body),
      params["secret_id"],
      Map.get(params, "idempotency_key", "")
    ]

    IO.iodata_to_binary([
      @domain | Enum.map(fields, &<<byte_size(&1)::unsigned-big-32, &1::binary>>)
    ])
  end

  defp valid_nonce?(nonce) do
    is_binary(nonce) and byte_size(nonce) == 64 and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, nonce)
  end

  defp valid_fields?(params) do
    Enum.all?(["biscuit", "audience", "method", "resource", "secret_id"], fn key ->
      value = params[key]
      is_binary(value) and value != "" and String.valid?(value)
    end) and
      Enum.all?(["body_b64", "idempotency_key", "public_key", "signature"], fn key ->
        value = Map.get(params, key, "")
        is_binary(value) and String.valid?(value)
      end)
  end

  defp request(params) do
    method = params["method"]
    url = params["resource"]

    if method in ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"] do
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

  defp call_upstream(method, url, secret, body, idempotency_key) do
    headers = [{"authorization", "Bearer " <> secret}]

    headers =
      if idempotency_key == "",
        do: headers,
        else: headers ++ [{"Idempotency-Key", idempotency_key}]

    case Req.request(
           method: method,
           url: url,
           redirect: false,
           headers: headers,
           body: body,
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
