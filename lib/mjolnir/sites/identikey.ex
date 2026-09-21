defmodule Mjolnir.Sites.IdentiKey do
  @moduledoc """
  ED25519 keypair management and signing for IdentiKey Sites.

  Owns key generation, signing, verification, fingerprinting, and JSON
  persistence. ML-DSA-87 (the second leg of the eventual MultiSig) will be
  layered on here once the recrypt Rust integration lands; for now only
  the ED25519 leg is wired.

  ## Fingerprint

  An IdentiKey fingerprint is the base58-encoded SHA-256 of the raw
  ED25519 public-key bytes. That is how live fps were minted while
  `Crypto.blake3_hash/1` was a SHA-256 stub. Content hashes are now real
  Blake3; fingerprints stay SHA-256 until a keyspace/alias migration.

  ## Wire format

  Keypairs are stored as JSON with base64-encoded key bytes:

      {
        "ed25519_public": "<base64>",
        "ed25519_secret": "<base64>"
      }

  ## Crypto backend

  Uses OTP's built-in `:crypto` module — no additional dependencies.
  """

  alias Mjolnir.Sites.Crypto

  @type keypair :: %{ed25519_public: binary(), ed25519_secret: binary()}

  @doc """
  Generate a fresh ED25519 keypair.

  Returns a map with 32-byte `ed25519_public` and 32-byte `ed25519_secret`.
  """
  @spec gen_keypair() :: keypair()
  def gen_keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    %{ed25519_public: pub, ed25519_secret: priv}
  end

  @doc """
  Sign `message` with the keypair's ED25519 secret key.

  Returns a 64-byte ED25519 signature.
  """
  @spec sign(keypair(), binary()) :: binary()
  def sign(%{ed25519_secret: secret}, message) when is_binary(message) do
    :crypto.sign(:eddsa, :none, message, [secret, :ed25519])
  end

  @doc """
  Verify an ED25519 `signature` over `message` using `public_key`.

  Returns `true` if the signature is valid, `false` otherwise.
  """
  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(public_key, message, signature)
      when is_binary(public_key) and is_binary(message) and is_binary(signature) do
    :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
  end

  @doc """
  Compute the IdentiKey fingerprint.

  Accepts either a `keypair()` map or raw public-key bytes. Returns the
  base58-encoded SHA-256 of the public-key bytes (see moduledoc).
  """
  @spec fingerprint(keypair() | binary()) :: String.t()
  def fingerprint(%{ed25519_public: pub}), do: fingerprint(pub)

  def fingerprint(pub) when is_binary(pub) do
    :crypto.hash(:sha256, pub) |> Crypto.base58_encode()
  end

  @doc """
  Serialize a keypair to a JSON string. Keys are base64-encoded.
  """
  @spec keypair_to_json(keypair()) :: String.t()
  def keypair_to_json(%{ed25519_public: pub, ed25519_secret: secret}) do
    %{
      "ed25519_public" => Base.encode64(pub),
      "ed25519_secret" => Base.encode64(secret)
    }
    |> Jason.encode!()
  end

  @doc """
  Deserialize a keypair from a JSON string produced by `keypair_to_json/1`.

  Returns `{:ok, keypair()}` on success or `{:error, term()}` on failure.
  """
  @spec keypair_from_json(String.t()) :: {:ok, keypair()} | {:error, term()}
  def keypair_from_json(json) when is_binary(json) do
    with {:ok, raw} <- Jason.decode(json),
         {:ok, pub_b64} <- Map.fetch(raw, "ed25519_public"),
         {:ok, sec_b64} <- Map.fetch(raw, "ed25519_secret"),
         {:ok, pub} <- Base.decode64(pub_b64),
         {:ok, sec} <- Base.decode64(sec_b64) do
      {:ok, %{ed25519_public: pub, ed25519_secret: sec}}
    else
      :error -> {:error, :missing_key}
      {:error, _} = err -> err
    end
  end
end
