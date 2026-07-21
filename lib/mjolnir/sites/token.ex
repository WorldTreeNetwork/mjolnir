defmodule Mjolnir.Sites.Token do
  @moduledoc """
  A scoped service credential for publishing IdentiKey Sites.

  Minted by an operator on the host (`mix mjolnir.sites.token create`) and handed
  to an unattended client — a Forgejo CI runner, typically. It is deliberately
  *not* a JWT: `Mjolnir.API.Auth` grants any valid JWT the full control-plane
  scope set, which is exactly what a CI job must not hold.

  ## Wire format

      Authorization: Bearer mjsk_<id>_<secret>

  `mjsk` ("Mjolnir sites key") makes the credential unmistakable in a header,
  a log, or a leaked file, and lets `Auth` route it without trial-verifying it
  as a JWT. `id` is 16 lowercase hex characters and is *not* secret — it is the
  primary key, safe to log, and is what `revoke` takes. `secret` is 32 bytes of
  `:crypto.strong_rand_bytes/1` in unpadded base64url.

  Because base64url's alphabet contains `_`, parsing splits into at most three
  parts (`parts: 3`) — the hex `id` never contains an underscore, so the
  remainder is the secret verbatim.

  ## What is stored

  Only `secret_hash`: `SHA-256(secret)`, base64-encoded. The plaintext exists
  once, in the mint task's output, and is never written to disk or logged. A
  lost token is re-minted, not recovered.

  SHA-256 rather than a password KDF (argon2/bcrypt) is deliberate: the secret
  is 256 bits of CSPRNG output, not a human-chosen password, so there is no
  dictionary to run and no reuse to protect against. Stretching would only tax
  the request path — this hash is computed on every authenticated publish
  request. This is the same posture as GitHub's personal access tokens.

  ## Binding

  Every token is bound to one `identikey_fp`, and optionally to one
  `site_name`. `Mjolnir.API.SitesRouter` enforces the binding against the `:fp`
  and `:name` path parameters, so a CI credential for one site cannot publish
  under another fingerprint. See `Mjolnir.Sites.TokenStore` for storage and
  `Mjolnir.API.Auth` for the request path.
  """

  @enforce_keys [:id, :secret_hash, :identikey_fp, :created_at]
  defstruct [
    :id,
    :secret_hash,
    :identikey_fp,
    :site_name,
    :created_at,
    :expires_at,
    :revoked_at,
    :description
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          secret_hash: String.t(),
          identikey_fp: String.t(),
          site_name: String.t() | nil,
          created_at: DateTime.t(),
          expires_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          description: String.t() | nil
        }

  @prefix "mjsk"
  @id_bytes 8
  @secret_bytes 32

  @doc "The scope a valid sites token confers. Deliberately disjoint from the control-plane scopes."
  @spec scope() :: String.t()
  def scope, do: "sites:publish"

  @doc """
  Mint a new token. Returns `{token_struct, plaintext}`.

  The plaintext is the only time the secret exists in full — the struct carries
  only its hash. Callers must show it to the operator and then drop it.
  """
  @spec mint(String.t(), keyword()) :: {t(), String.t()}
  def mint(identikey_fp, opts \\ []) when is_binary(identikey_fp) do
    id = Base.encode16(:crypto.strong_rand_bytes(@id_bytes), case: :lower)
    secret = Base.url_encode64(:crypto.strong_rand_bytes(@secret_bytes), padding: false)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    token = %__MODULE__{
      id: id,
      secret_hash: hash_secret(secret),
      identikey_fp: identikey_fp,
      site_name: Keyword.get(opts, :site_name),
      created_at: now,
      expires_at: Keyword.get(opts, :expires_at),
      revoked_at: nil,
      description: Keyword.get(opts, :description)
    }

    {token, "#{@prefix}_#{id}_#{secret}"}
  end

  @doc """
  True if `raw` looks like a sites token. Used by `Mjolnir.API.Auth` to route a
  bearer credential without trial-verifying it as a JWT.
  """
  @spec looks_like_token?(String.t()) :: boolean()
  def looks_like_token?(raw) when is_binary(raw), do: String.starts_with?(raw, @prefix <> "_")
  def looks_like_token?(_), do: false

  @doc """
  Split a presented credential into `{id, secret}`.

  Returns `:error` for anything malformed. The `id` is safe to log; the secret
  is not.
  """
  @spec parse(String.t()) :: {:ok, {String.t(), String.t()}} | :error
  def parse(raw) when is_binary(raw) do
    case String.split(raw, "_", parts: 3) do
      [@prefix, id, secret] when id != "" and secret != "" -> {:ok, {id, secret}}
      _ -> :error
    end
  end

  def parse(_), do: :error

  @doc "Base64 `SHA-256` of a secret. The only representation that reaches disk."
  @spec hash_secret(String.t()) :: String.t()
  def hash_secret(secret) when is_binary(secret) do
    :crypto.hash(:sha256, secret) |> Base.encode64()
  end

  @doc """
  Constant-time check of a presented secret against a stored token.

  Both sides are fixed-length base64 SHA-256 digests, so there is no length
  side-channel to leak and `Plug.Crypto.secure_compare/2` never sees mismatched
  sizes.
  """
  @spec secret_valid?(t(), String.t()) :: boolean()
  def secret_valid?(%__MODULE__{secret_hash: stored}, presented) when is_binary(presented) do
    Plug.Crypto.secure_compare(stored, hash_secret(presented))
  end

  def secret_valid?(_, _), do: false

  @doc "True once `revoked_at` is set. Revocation is permanent; tokens are re-minted, not un-revoked."
  @spec revoked?(t()) :: boolean()
  def revoked?(%__MODULE__{revoked_at: nil}), do: false
  def revoked?(%__MODULE__{}), do: true

  @doc "True once `expires_at` has passed. A `nil` expiry never expires."
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(token, now \\ DateTime.utc_now())
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false

  def expired?(%__MODULE__{expires_at: at}, now), do: DateTime.compare(now, at) != :lt

  @doc """
  Whether this token may act on `(fp, site_name)`.

  `site_name` may be `nil` for endpoints that carry no site in their path; a
  token bound to a specific site still permits those (the fingerprint is what
  scopes them).
  """
  @spec authorizes?(t(), String.t(), String.t() | nil) :: boolean()
  def authorizes?(%__MODULE__{} = token, fp, site_name) do
    token.identikey_fp == fp and
      (is_nil(token.site_name) or is_nil(site_name) or token.site_name == site_name)
  end

  ## Serialization — one JSON object per token on disk.

  @doc false
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = t) do
    %{
      "id" => t.id,
      "secret_hash" => t.secret_hash,
      "identikey_fp" => t.identikey_fp,
      "site_name" => t.site_name,
      "created_at" => DateTime.to_iso8601(t.created_at),
      "expires_at" => t.expires_at && DateTime.to_iso8601(t.expires_at),
      "revoked_at" => t.revoked_at && DateTime.to_iso8601(t.revoked_at),
      "description" => t.description
    }
  end

  @doc false
  @spec from_json(map()) :: {:ok, t()} | {:error, term()}
  def from_json(%{} = m) do
    with {:ok, created} <- parse_dt(m["created_at"]),
         {:ok, expires} <- parse_dt_maybe(m["expires_at"]),
         {:ok, revoked} <- parse_dt_maybe(m["revoked_at"]),
         true <- is_binary(m["id"]) and is_binary(m["secret_hash"]),
         true <- is_binary(m["identikey_fp"]) do
      {:ok,
       %__MODULE__{
         id: m["id"],
         secret_hash: m["secret_hash"],
         identikey_fp: m["identikey_fp"],
         site_name: m["site_name"],
         created_at: created,
         expires_at: expires,
         revoked_at: revoked,
         description: m["description"]
       }}
    else
      _ -> {:error, :invalid_token_record}
    end
  end

  def from_json(_), do: {:error, :invalid_token_record}

  defp parse_dt(nil), do: {:error, :missing}

  defp parse_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, :bad_datetime}
    end
  end

  defp parse_dt(_), do: {:error, :bad_datetime}

  defp parse_dt_maybe(nil), do: {:ok, nil}
  defp parse_dt_maybe(s), do: parse_dt(s)
end
