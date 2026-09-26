defmodule Mjolnir.Deploy.Owner do
  @moduledoc """
  Who a deploy is stamped as.

  A loopback deploy with no credential authenticates as `localhost`. That
  string is not an account. The host names the real owner with `X-Owner-Id`.
  The value is the canonical base58 text form of a 32-byte XID (Bitcoin
  alphabet, leading `0x00` kept as `1`). That is the identikey-protocol
  spelling of a short id, and it is the public OIDC `sub`.

  Hex is not an identifier. A 64-hex header is rejected. A row already stored
  as 64 lowercase hex is the old spelling of the same 32 bytes: `claim/2`
  accepts it and the deploy rewrites the stored string.

  Any caller who is not the loopback bypass is stamped as themselves. The
  header does not let them impersonate.
  """

  @hex ~r/^[0-9a-f]{64}$/

  @type claim :: :ok | {:rewrite, String.t()} | {:error, :owner_mismatch}

  @doc """
  Canonical base58 XID, or `:error`.

  The decoded bytes must be exactly 32, and `text` must equal the canonical
  re-encode. Whitespace is trimmed. Hex is `:error`.
  """
  @spec parse(term()) :: {:ok, String.t()} | :error
  def parse(text) when is_binary(text) do
    trimmed = String.trim(text)

    with {:ok, bytes} <- decode32(trimmed),
         canonical when canonical == trimmed <- encode(bytes) do
      {:ok, canonical}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  @doc "True when `parse/1` accepts `text`."
  @spec canonical?(term()) :: boolean()
  def canonical?(text), do: match?({:ok, _}, parse(text))

  @spec resolve(String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, :owner_required | :invalid_owner}
  def resolve("localhost", header) when is_binary(header) do
    case parse(header) do
      {:ok, owner} -> {:ok, owner}
      :error -> {:error, :invalid_owner}
    end
  end

  def resolve("localhost", _), do: {:error, :owner_required}

  def resolve(user_id, _) when is_binary(user_id) and user_id != "", do: {:ok, user_id}

  def resolve(_, _), do: {:error, :owner_required}

  @doc """
  Whether loopback may stamp `canonical` onto an app that currently stores
  `stored`.

  `nil` and `"localhost"` may be backfilled. The same 32 bytes stored as hex
  return `{:rewrite, canonical}`. A different XID is `:owner_mismatch`.
  """
  @spec claim(String.t() | nil, String.t()) :: claim()
  def claim(stored, _canonical) when stored in [nil, "localhost"], do: :ok

  def claim(stored, canonical) when is_binary(stored) and is_binary(canonical) do
    with {:ok, want} <- decode32(canonical),
         {:ok, have} <- decode_stored(stored) do
      cond do
        have != want -> {:error, :owner_mismatch}
        stored == canonical -> :ok
        true -> {:rewrite, canonical}
      end
    else
      _ -> {:error, :owner_mismatch}
    end
  end

  def claim(_, _), do: {:error, :owner_mismatch}

  @doc """
  Owner string to persist on a registry entry.

  A canonical XID in `opt` wins (this is the hex→base58 rewrite). A
  non-canonical `opt` (`nil`, `"localhost"`, hex, anything else) must not
  replace a canonical owner already stored. Otherwise `opt` is kept, including
  a legacy hex `sub` on a first deploy, so a token that has not moved spelling
  yet still matches `owner_id`.
  """
  @spec stamp(String.t() | nil, String.t() | nil) :: String.t() | nil
  def stamp(opt, prev) do
    cond do
      canonical?(prev) and not canonical?(opt) -> prev
      opt in [nil, "localhost"] -> prev
      true -> opt
    end
  end

  @doc """
  True when both values name the same owner.

  Exact strings match, including non-XID labels such as `"alice"`. A
  canonical base58 XID and the legacy 64-lowercase-hex spelling of those
  same 32 bytes also match. This does not rehash the key.
  """
  @spec same?(term(), term()) :: boolean()
  def same?(left, right) when is_binary(left) and is_binary(right) do
    left == right or same_xid?(left, right)
  end

  def same?(_, _), do: false

  @spec encode(binary()) :: String.t()
  def encode(bytes) when is_binary(bytes), do: Mjolnir.Base58.encode(bytes)

  defp decode_stored(text) do
    case decode32(text) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> decode_legacy_hex(text)
    end
  end

  defp decode_legacy_hex(text) when is_binary(text) do
    if Regex.match?(@hex, text) do
      Base.decode16(text, case: :lower)
    else
      :error
    end
  end

  defp decode32(text), do: Mjolnir.Base58.decode(text, 32)

  defp same_xid?(left, right) do
    case {decode_stored(left), decode_stored(right)} do
      {{:ok, bytes}, {:ok, bytes}} -> true
      _ -> false
    end
  end
end
