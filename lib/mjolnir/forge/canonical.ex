defmodule Mjolnir.Forge.Canonical do
  @moduledoc """
  Deterministic encoding for resource content. Produces the same byte string
  for the same content regardless of map iteration order, so that
  `hash(encode(x)) == hash(encode(x))` byte-for-byte across nodes and runs.

  Strategy:
    * map keys: recursively sort by stringified key; emit a JSON object
    * lists: preserve order (semantically significant); emit a JSON array
    * structs: convert to a plain map first
    * atoms (non-boolean, non-nil): stringify
    * binaries/numbers/booleans/nil: emit as Jason would

  SHA-256 over the canonical bytes is the content hash. The original design
  called for canonical CBOR + blake3; we use sorted-key JSON + SHA-256 because
  Jason is already a dependency, `:crypto.hash/2` is in OTP, and the hash is
  only used for equality (not cryptographic) purposes.
  """

  @spec encode(term()) :: binary()
  def encode(term), do: IO.iodata_to_binary(do_encode(term))

  @spec hash(term()) :: binary()
  def hash(term), do: :crypto.hash(:sha256, encode(term))

  @spec hash_hex(term()) :: String.t()
  def hash_hex(term), do: term |> hash() |> Base.encode16(case: :lower)

  @spec hash_bytes(binary()) :: binary()
  def hash_bytes(bytes) when is_binary(bytes), do: :crypto.hash(:sha256, bytes)

  defp do_encode(struct) when is_struct(struct), do: do_encode(Map.from_struct(struct))

  defp do_encode(map) when is_map(map) do
    pairs =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> [Jason.encode!(k), ":", do_encode(v)] end)
      |> Enum.intersperse(",")

    ["{", pairs, "}"]
  end

  defp do_encode(list) when is_list(list) do
    items = list |> Enum.map(&do_encode/1) |> Enum.intersperse(",")
    ["[", items, "]"]
  end

  defp do_encode(nil), do: "null"
  defp do_encode(true), do: "true"
  defp do_encode(false), do: "false"
  defp do_encode(atom) when is_atom(atom), do: Jason.encode!(Atom.to_string(atom))
  defp do_encode(other), do: Jason.encode!(other)
end
