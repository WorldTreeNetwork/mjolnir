defmodule Mjolnir.Sites.MultiSig do
  @moduledoc """
  Forward-compatible signature envelope for IdentiKey-signed records.

  A `MultiSig` is a *bundle of independent signature legs* over the same
  canonical signing bytes. Today only the ED25519 leg is populated; the eventual
  dual-stack identity adds an ML-DSA-87 leg (post-quantum) alongside it without
  changing the wire format or any caller.

  ## Why a struct, not a bare binary

  Records (manifest, HEAD, alias) historically carried the signature as a single
  base64-encoded ED25519 binary. That shape cannot grow a second algorithm leg
  without an ambiguous re-interpretation of the bytes. `MultiSig` makes the leg
  set explicit:

      %MultiSig{ed25519: <<64 bytes>>, ml_dsa_87: nil}

  Adding ML-DSA later is purely additive — populate `:ml_dsa_87`, bump the
  verifier to require both legs, no manifest/record schema migration.

  ## Wire format

  On the JSON envelope the signature field is an object keyed by algorithm:

      "signatures": { "ed25519": "<base64>" }      # manifest
      "signature":  { "ed25519": "<base64>" }      # HEAD / alias

  Each leg value is the base64-encoded raw signature bytes for that algorithm.
  Absent/`nil` legs are omitted. An ML-DSA leg will appear as an additional
  `"ml_dsa_87"` key with no other change.

  ## Backward compatibility

  `from_field/1` also accepts the *legacy* bare base64-string shape (a single
  ED25519 signature) and a raw binary, so envelopes written before the struct
  landed still parse. New writes always use the object shape via `to_field/1`.
  """

  alias Mjolnir.Sites.IdentiKey

  defstruct ed25519: nil, ml_dsa_87: nil

  @type t :: %__MODULE__{
          ed25519: binary() | nil,
          ml_dsa_87: binary() | nil
        }

  @doc """
  Build a `MultiSig` by signing `signing_bytes` with `keypair`'s ED25519 secret.

  The ML-DSA leg is left `nil` until that algorithm is wired.
  """
  @spec sign(IdentiKey.keypair(), binary()) :: t()
  def sign(keypair, signing_bytes) when is_binary(signing_bytes) do
    %__MODULE__{ed25519: IdentiKey.sign(keypair, signing_bytes)}
  end

  @doc """
  Verify a `MultiSig` over `signing_bytes` against the signer's ED25519
  `public_key`.

  Phase 1 policy: the ED25519 leg must be present and valid. Additional legs,
  once present, will be required here too (dual-stack AND-semantics).
  """
  @spec verify(t(), binary(), binary()) :: boolean()
  def verify(%__MODULE__{ed25519: sig}, public_key, signing_bytes)
      when is_binary(sig) and is_binary(public_key) and is_binary(signing_bytes) do
    IdentiKey.verify(public_key, signing_bytes, sig)
  end

  def verify(%__MODULE__{}, _public_key, _signing_bytes), do: false

  @doc """
  Encode a `MultiSig` (or `nil`) into the JSON-serializable field value.

  Returns `nil` for an empty/`nil` signature so that `canonical_signing_bytes`
  (which clears the field) produces stable bytes on both the signing and
  verifying side. Otherwise returns a map of `algorithm => base64` for every
  populated leg.
  """
  @spec to_field(t() | nil) :: map() | nil
  def to_field(nil), do: nil

  def to_field(%__MODULE__{ed25519: nil, ml_dsa_87: nil}), do: nil

  def to_field(%__MODULE__{} = sig) do
    [{"ed25519", sig.ed25519}, {"ml_dsa_87", sig.ml_dsa_87}]
    |> Enum.reduce(%{}, fn
      {_alg, nil}, acc -> acc
      {alg, bytes}, acc when is_binary(bytes) -> Map.put(acc, alg, Base.encode64(bytes))
    end)
  end

  @doc """
  Decode a JSON field value back into a `MultiSig`.

  Accepts:
    * the object shape `%{"ed25519" => base64, ...}` (current);
    * a legacy bare base64 string (single ED25519 signature);
    * a raw binary (single ED25519 signature, not base64);
    * `nil`.

  Returns `nil` when there is no signature material.
  """
  @spec from_field(map() | binary() | nil) :: t() | nil
  def from_field(nil), do: nil

  def from_field(%{} = obj) do
    sig = %__MODULE__{
      ed25519: decode_leg(Map.get(obj, "ed25519")),
      ml_dsa_87: decode_leg(Map.get(obj, "ml_dsa_87"))
    }

    if sig.ed25519 == nil and sig.ml_dsa_87 == nil, do: nil, else: sig
  end

  def from_field(str) when is_binary(str) do
    case Base.decode64(str) do
      {:ok, bin} -> %__MODULE__{ed25519: bin}
      :error -> %__MODULE__{ed25519: str}
    end
  end

  defp decode_leg(nil), do: nil

  defp decode_leg(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bin} -> bin
      :error -> nil
    end
  end
end
