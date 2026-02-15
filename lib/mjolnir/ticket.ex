defmodule Mjolnir.Ticket do
  @moduledoc """
  Ticket encoding for 32-byte Iroh node IDs.

  Uses z32 (z-base-32): case-insensitive, DNS-safe, 52 chars for 32 bytes.
  This is Iroh's native encoding, used in DNS discovery, mDNS, pkarr records,
  and web gateway subdomains: `<z32>.vm.worldtree.network`
  """

  # z-base-32 alphabet (Iroh's native format for DNS discovery)
  @z32_alphabet ~c"ybndrfg8ejkmcpqxot1uwisza345h769"

  @doc """
  Convert a hex-encoded node ID to a z32 (z-base-32) ticket string.
  """
  def from_hex(nil), do: nil

  def from_hex(hex) do
    hex
    |> Base.decode16!(case: :lower)
    |> z32_encode()
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
