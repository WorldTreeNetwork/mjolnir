defmodule Mjolnir.VmId do
  @moduledoc """
  VM ids are 16 random bytes. The text form is base58btc.

  A UUID (`8-4-4-4-12` hex) is the same 16 bytes with dashes. `canonicalize/1`
  accepts either spelling and returns the base58 form. A 32-byte value (an
  account XID or a fingerprint) is rejected so it cannot be used as a VM id.

  The alphabet and the "short id at a text boundary is base58" rule are
  identikey-protocol `docs/standards/encoding-conventions.md`. This is not a
  XID: a XID is SHA-256 of an inception signing key.
  """

  @alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  @index Map.new(Enum.with_index(@alphabet))
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @doc "New id. `UUID.uuid4/0` supplies the 16 bytes (version nibble included)."
  @spec generate() :: String.t()
  def generate do
    {:ok, text} = canonicalize(UUID.uuid4())
    text
  end

  @doc """
  Base58btc form of a UUID or of an existing base58 VM id.

  Returns `:error` for anything that is not exactly 16 bytes in one of those
  two spellings.
  """
  @spec canonicalize(term()) :: {:ok, String.t()} | :error
  def canonicalize(id) when is_binary(id) do
    cond do
      Regex.match?(@uuid, id) ->
        {:ok, id |> String.replace("-", "") |> Base.decode16!(case: :lower) |> encode()}

      true ->
        case decode(id) do
          {:ok, <<bytes::binary-size(16)>>} -> {:ok, encode(bytes)}
          _ -> :error
        end
    end
  end

  def canonicalize(_), do: :error

  @doc """
  Canonical spelling when `id` is a VM id, otherwise `id` unchanged.

  Non-ids (`"vm-1"`, a snapshot name) pass through so callers that are not
  looking at a VM id do not have to special-case them.
  """
  @spec storage_id(String.t()) :: String.t()
  def storage_id(id) when is_binary(id) do
    case canonicalize(id) do
      {:ok, canonical} -> canonical
      :error -> id
    end
  end

  @doc "True when `id` is the dashed UUID spelling."
  @spec legacy_uuid?(term()) :: boolean()
  def legacy_uuid?(id) when is_binary(id), do: Regex.match?(@uuid, id)
  def legacy_uuid?(_), do: false

  @spec encode(binary()) :: String.t()
  def encode(bytes) when is_binary(bytes) do
    zeros = leading_zeros(bytes)
    digits = bytes |> :binary.decode_unsigned() |> digits()
    String.duplicate("1", zeros) <> IO.iodata_to_binary(Enum.reverse(digits))
  end

  defp digits(0), do: []

  defp digits(n) do
    [Enum.at(@alphabet, rem(n, 58)) | digits(div(n, 58))]
  end

  defp leading_zeros(<<0, rest::binary>>), do: 1 + leading_zeros(rest)
  defp leading_zeros(_), do: 0

  @spec decode(String.t()) :: {:ok, binary()} | :error
  def decode(text) when is_binary(text) and text != "" do
    # 16 bytes is at most 22 base58 characters. A 32-byte XID is 43–44.
    if byte_size(text) > 22 do
      :error
    else
      case accumulate(text, 0, 0) do
        {:ok, zeros, n} ->
          body =
            case n do
              0 -> <<>>
              _ -> :binary.encode_unsigned(n)
            end

          packed = :binary.copy(<<0>>, zeros) <> body

          if byte_size(packed) == 16 do
            {:ok, packed}
          else
            :error
          end

        :error ->
          :error
      end
    end
  end

  def decode(_), do: :error

  defp accumulate(<<>>, zeros, n), do: {:ok, zeros, n}

  defp accumulate(<<char, rest::binary>>, zeros, n) do
    case Map.fetch(@index, char) do
      {:ok, digit} ->
        zeros = if n == 0 and digit == 0, do: zeros + 1, else: zeros
        accumulate(rest, zeros, n * 58 + digit)

      :error ->
        :error
    end
  end
end
