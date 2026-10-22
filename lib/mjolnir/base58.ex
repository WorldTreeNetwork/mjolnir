defmodule Mjolnir.Base58 do
  @moduledoc """
  Base58 from identikey-protocol encoding conventions.

  The alphabet is Bitcoin's, with `0`, `O`, `I`, and `l` removed. The value
  is the raw bytes: no version byte and no checksum. A leading zero byte
  encodes as a leading `1`. Hex is not this encoding.
  """

  @alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  @index Map.new(Enum.with_index(@alphabet))
  # 256 input bytes is the convention's base58 ceiling. The text is longer.
  @max_text 352

  @doc "Encode raw bytes. A leading zero byte becomes a leading `1`."
  @spec encode(binary()) :: String.t()
  def encode(bytes) when is_binary(bytes) do
    zeros = leading_zeros(bytes)
    digits = bytes |> :binary.decode_unsigned() |> digits()
    String.duplicate("1", zeros) <> IO.iodata_to_binary(Enum.reverse(digits))
  end

  @doc "Decode text to the original bytes, or `:error`."
  @spec decode(term()) :: {:ok, binary()} | :error
  def decode(text) when is_binary(text) and text != "" and byte_size(text) <= @max_text do
    case accumulate(text, 0, 0) do
      {:ok, zeros, n} ->
        body =
          case n do
            0 -> <<>>
            _ -> :binary.encode_unsigned(n)
          end

        {:ok, :binary.copy(<<0>>, zeros) <> body}

      :error ->
        :error
    end
  end

  def decode(_), do: :error

  @doc "Decode text that is exactly `size` bytes, or `:error`."
  @spec decode(term(), pos_integer()) :: {:ok, binary()} | :error
  def decode(text, size) when is_integer(size) and size > 0 do
    case decode(text) do
      {:ok, bytes} when byte_size(bytes) == size -> {:ok, bytes}
      _ -> :error
    end
  end

  defp digits(0), do: []
  defp digits(n), do: [Enum.at(@alphabet, rem(n, 58)) | digits(div(n, 58))]

  defp leading_zeros(<<0, rest::binary>>), do: 1 + leading_zeros(rest)
  defp leading_zeros(_), do: 0

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
