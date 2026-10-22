defmodule Mjolnir.Sites.WrapShape do
  @moduledoc """
  Shape check for a caller-supplied data-key wrap.

  The bytes must be one definite CBOR item, a map, with top-level `alg`
  `x25519-xchacha20poly1305` and a 48-byte `ciphertext`. That is the floor of
  `identikey-keys` `encode_wrap` (32-byte key plus a 16-byte tag). Trailing
  bytes, indefinite lengths, and a raw 32-byte key are refused.

  Nested values are walked only far enough to reach the next top-level key.
  Nothing is decrypted.
  """

  import Bitwise

  @max_bytes 4096
  @alg "x25519-xchacha20poly1305"

  @doc "True when `wrap` is a bounded CBOR map of the key-wrap shape."
  @spec valid?(term()) :: boolean()
  def valid?(<<wrap::binary>>) when byte_size(wrap) in 1..@max_bytes do
    case value(wrap, 0) do
      {:ok, {:map, pairs}, offset} when offset == byte_size(wrap) ->
        match?({:ok, {:text, @alg}}, field(pairs, "alg")) and
          match?({:ok, {:bytes, <<_::binary-size(48)>>}}, field(pairs, "ciphertext"))

      _ ->
        false
    end
  end

  def valid?(_), do: false

  defp field(pairs, key) do
    case for {{:text, ^key}, value} <- pairs, do: value do
      [value] -> {:ok, value}
      _ -> :error
    end
  end

  defp value(bin, i) do
    with {:ok, major, arg, i} <- header(bin, i) do
      case major do
        0 ->
          {:ok, {:uint, arg}, i}

        1 ->
          {:ok, {:nint, arg}, i}

        2 ->
          take(bin, i, arg, :bytes)

        3 ->
          take(bin, i, arg, :text)

        4 ->
          elements(bin, i, arg, [])

        5 ->
          pairs(bin, i, arg, [])

        6 ->
          case value(bin, i) do
            {:ok, inner, i} -> {:ok, {:tag, arg, inner}, i}
            other -> other
          end

        7 ->
          {:ok, :simple, i}

        _ ->
          :error
      end
    end
  end

  defp elements(_bin, i, 0, acc), do: {:ok, {:array, Enum.reverse(acc)}, i}

  defp elements(bin, i, n, acc) when is_integer(n) and n > 0 and n <= @max_bytes do
    case value(bin, i) do
      {:ok, item, i} -> elements(bin, i, n - 1, [item | acc])
      other -> other
    end
  end

  defp elements(_, _, _, _), do: :error

  defp pairs(_bin, i, 0, acc), do: {:ok, {:map, Enum.reverse(acc)}, i}

  defp pairs(bin, i, n, acc) when is_integer(n) and n > 0 and n <= @max_bytes do
    with {:ok, key, i} <- value(bin, i),
         {:ok, val, i} <- value(bin, i) do
      pairs(bin, i, n - 1, [{key, val} | acc])
    end
  end

  defp pairs(_, _, _, _), do: :error

  defp take(bin, i, len, kind)
       when is_integer(len) and len >= 0 and len <= @max_bytes and i + len <= byte_size(bin) do
    data = binary_part(bin, i, len)

    cond do
      kind == :text and not String.valid?(data) -> :error
      true -> {:ok, {kind, data}, i + len}
    end
  end

  defp take(_, _, _, _), do: :error

  defp header(bin, i) when is_integer(i) and i >= 0 and i < byte_size(bin) do
    <<_::binary-size(i), byte, _::binary>> = bin
    major = bsr(byte, 5)
    ai = band(byte, 31)

    cond do
      ai < 24 -> {:ok, major, ai, i + 1}
      ai == 24 -> read_be(bin, i + 1, 1, major)
      ai == 25 -> read_be(bin, i + 1, 2, major)
      ai == 26 -> read_be(bin, i + 1, 4, major)
      ai == 27 -> read_be(bin, i + 1, 8, major)
      true -> :error
    end
  end

  defp header(_, _), do: :error

  defp read_be(bin, i, n, major) when i + n <= byte_size(bin) do
    <<arg::unsigned-big-integer-size(n * 8)>> = binary_part(bin, i, n)
    {:ok, major, arg, i + n}
  end

  defp read_be(_, _, _, _), do: :error
end
