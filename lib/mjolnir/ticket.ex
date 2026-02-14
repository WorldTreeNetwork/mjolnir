defmodule Mjolnir.Ticket do
  @moduledoc """
  Ticket encoding for 32-byte Iroh node IDs.

  Supports two formats:
  - **base58**: Bitcoin-style (~44 chars), used by the CLI
  - **z32** (z-base-32): Case-insensitive (~52 chars), DNS-safe, used for web gateway subdomains

  The full iroh JSON EndpointAddr is only used for debugging/interop.
  """

  # Bitcoin-style base58 alphabet (no 0, O, I, l)
  @base58_alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  # z-base-32 alphabet (Iroh's native format for DNS discovery)
  @z32_alphabet ~c"ybndrfg8ejkmcpqxot1uwisza345h769"

  @doc """
  Convert a hex-encoded node ID to a base58 ticket string.
  """
  def from_hex(nil), do: nil

  def from_hex(hex) do
    hex
    |> Base.decode16!(case: :lower)
    |> base58_encode()
  end

  @doc """
  Convert a hex-encoded node ID to a z32 (z-base-32) string.

  z32 is case-insensitive and DNS-safe (52 chars for 32 bytes).
  Used for web gateway subdomains: `<z32>.vm.worldtree.network`
  """
  def z32_from_hex(nil), do: nil

  def z32_from_hex(hex) do
    hex
    |> Base.decode16!(case: :lower)
    |> z32_encode()
  end

  defp base58_encode(<<>>), do: ""

  defp base58_encode(bytes) do
    leading_zeros = bytes |> :binary.bin_to_list() |> Enum.take_while(&(&1 == 0)) |> length()
    prefix = String.duplicate("1", leading_zeros)

    num = :binary.decode_unsigned(bytes, :big)
    encoded = base58_encode_int(num, [])

    prefix <> encoded
  end

  defp base58_encode_int(0, []), do: ""
  defp base58_encode_int(0, acc), do: IO.iodata_to_binary(acc)

  defp base58_encode_int(num, acc) do
    char = Enum.at(@base58_alphabet, rem(num, 58))
    base58_encode_int(div(num, 58), [char | acc])
  end

  # z-base-32 encoding: 5-bit groups from the binary, mapped to the z32 alphabet.
  # For 32 bytes (256 bits) this produces exactly 52 characters (52 * 5 = 260 bits,
  # 4 trailing padding bits are zero).
  defp z32_encode(<<>>) do
    ""
  end

  defp z32_encode(bytes) do
    bits = for <<b::1 <- bytes>>, do: b

    bits
    |> pad_to_multiple(5)
    |> Enum.chunk_every(5)
    |> Enum.map(fn chunk ->
      index = Enum.reduce(chunk, 0, fn bit, acc -> acc * 2 + bit end)
      Enum.at(@z32_alphabet, index)
    end)
    |> IO.iodata_to_binary()
  end

  defp pad_to_multiple(bits, n) do
    remainder = rem(length(bits), n)

    if remainder == 0 do
      bits
    else
      bits ++ List.duplicate(0, n - remainder)
    end
  end
end
