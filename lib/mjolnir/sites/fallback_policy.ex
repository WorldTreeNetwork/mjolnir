defmodule Mjolnir.Sites.FallbackPolicy do
  @moduledoc "Signed site-wide fallback policy stored separately from HEAD."

  alias Mjolnir.SecretStore
  alias Mjolnir.Sites.{IdentiKey, MultiSig}

  defstruct [:fallback, :sequence, :identikey_fp, :site_name, :created_at, :signature]

  def serialize(%__MODULE__{} = policy) do
    %{
      "fallback" => encode_fallback(policy.fallback),
      "sequence" => policy.sequence,
      "identikey_fp" => policy.identikey_fp,
      "site_name" => policy.site_name,
      "created_at" => DateTime.to_iso8601(policy.created_at),
      "signature" => encode_signature(policy.signature)
    }
    |> Jason.encode!()
  end

  def canonical_signing_bytes(%__MODULE__{} = policy), do: serialize(%{policy | signature: nil})

  def parse(bytes) when is_binary(bytes) do
    with {:ok, raw} <- Jason.decode(bytes),
         {:ok, fallback} <- decode_fallback(Map.get(raw, "fallback")),
         {:ok, created_at, _} <- DateTime.from_iso8601(Map.fetch!(raw, "created_at")) do
      {:ok,
       %__MODULE__{
         fallback: fallback,
         sequence: Map.fetch!(raw, "sequence"),
         identikey_fp: Map.fetch!(raw, "identikey_fp"),
         site_name: Map.fetch!(raw, "site_name"),
         created_at: created_at,
         signature: decode_signature(Map.get(raw, "signature"))
       }}
    else
      _ -> {:error, :bad_fallback_policy}
    end
  rescue
    _ -> {:error, :bad_fallback_policy}
  end

  def verify(%__MODULE__{} = policy) do
    with signature when is_binary(signature) <- policy.signature,
         {:ok, identity} <- SecretStore.get(policy.identikey_fp, "identity/pubkey"),
         {:ok, %{"pubkey" => encoded}} <- Jason.decode(identity),
         {:ok, public_key} <- Base.decode64(encoded),
         true <- IdentiKey.fingerprint(public_key) == policy.identikey_fp,
         true <- IdentiKey.verify(public_key, canonical_signing_bytes(policy), signature) do
      :ok
    else
      _ -> {:error, :bad_fallback_signature}
    end
  end

  def materialized_value(%__MODULE__{fallback: :index}), do: "index.html"
  def materialized_value(%__MODULE__{fallback: :not_found}), do: "404.html"
  def materialized_value(%__MODULE__{fallback: :empty}), do: "false"

  defp encode_fallback(:index), do: "index.html"
  defp encode_fallback(:not_found), do: "404.html"
  defp encode_fallback(:empty), do: false

  defp decode_fallback("index.html"), do: {:ok, :index}
  defp decode_fallback("404.html"), do: {:ok, :not_found}
  defp decode_fallback(false), do: {:ok, :empty}
  defp decode_fallback(_), do: {:error, :invalid_fallback}

  defp encode_signature(nil), do: nil
  defp encode_signature(<<>>), do: nil

  defp encode_signature(signature) when is_binary(signature),
    do: MultiSig.to_field(%MultiSig{ed25519: signature})

  defp decode_signature(field) do
    case MultiSig.from_field(field) do
      %MultiSig{ed25519: signature} -> signature
      nil -> nil
    end
  end
end
