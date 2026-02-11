defmodule Mjolnir.Ticket do
  @moduledoc """
  Compact ticket format: base58-encoded 32-byte node ID.

  This is the primary format users interact with (~44 chars).
  The full iroh JSON EndpointAddr is only used for debugging/interop.
  """

  # Bitcoin-style base58 alphabet (no 0, O, I, l)
  @base58_alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  @doc """
  Convert a hex-encoded node ID to a base58 ticket string.
  """
  def from_hex(nil), do: nil

  def from_hex(hex) do
    hex
    |> Base.decode16!(case: :lower)
    |> base58_encode()
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
end
