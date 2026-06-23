defmodule Mjolnir.Sites.Crypto do
  @moduledoc """
  Cryptographic primitives used by the sites subsystem. This module is the
  single seam between Elixir-side site logic and the underlying crypto. All
  callers MUST go through this module — never directly to a NIF or shell tool.

  See `docs/plans/initiatives/identikey-sites.md` §6.1 for how these compose.

  ## Implementations

  - Blake3 — `:blake3` NIF (Rust, 1.x)
  - HKDF-SHA256 — `:crypto` HMAC-SHA256 (RFC 5869)
  - XChaCha20 — HChaCha20 nonce extension + `:crypto` ChaCha20 (raw stream,
    no auth tag; wire-compatible with RFC draft-irtf-cfrg-xchacha §2.3)

  ## API stability

  These signatures are FROZEN for the rest of Phase 1.
  """

  @doc """
  Blake3 hash of bytes. Returns raw 32-byte digest.

  STUB: SHA-256 placeholder until the Blake3 NIF is wired via recrypt.
  Same 32-byte shape; not wire-compatible with real Blake3.
  """
  @spec blake3_hash(binary()) :: binary()
  def blake3_hash(bytes) when is_binary(bytes) do
    :crypto.hash(:sha256, bytes)
  end

  @doc """
  Blake3 hash returned as a base58-encoded string. Convenience wrapper around
  `blake3_hash/1` + `base58_encode/1`.
  """
  @spec blake3_hash_base58(binary()) :: String.t()
  def blake3_hash_base58(bytes) when is_binary(bytes) do
    bytes |> blake3_hash() |> base58_encode()
  end

  @doc """
  HKDF-SHA256 key derivation per RFC 5869. Returns `length` bytes of output
  keying material derived from `ikm` (input keying material) with `info` as
  the context string and an empty salt.

  Implemented via `:crypto.mac/4` with HMAC-SHA256.
  """
  @spec hkdf_sha256(binary(), binary(), pos_integer()) :: binary()
  def hkdf_sha256(ikm, info, length)
      when is_binary(ikm) and is_binary(info) and is_integer(length) and length > 0 do
    # Extract: PRK = HMAC-SHA256(salt=<zeros>, ikm)
    prk = :crypto.mac(:hmac, :sha256, <<0::256>>, ikm)
    # Expand
    expand_hkdf(prk, info, length, "", 1, "")
  end

  defp expand_hkdf(_prk, _info, length, acc, _i, _last) when byte_size(acc) >= length do
    binary_part(acc, 0, length)
  end

  defp expand_hkdf(prk, info, length, acc, i, last) do
    block = :crypto.mac(:hmac, :sha256, prk, last <> info <> <<i>>)
    expand_hkdf(prk, info, length, acc <> block, i + 1, block)
  end

  @doc """
  Encrypt with XChaCha20 (raw stream cipher, no auth tag). Returns ciphertext
  of the same length as `plaintext`.

  Arguments:
    * `key` — 32 bytes
    * `nonce` — 24 bytes
    * `plaintext` — any length

  Wire-compatible with draft-irtf-cfrg-xchacha §2.3: nonce[0:16] is consumed
  by HChaCha20 to derive a subkey; the remaining nonce[16:24] (plus 4 zero
  bytes) forms the 12-byte ChaCha20 nonce.
  """
  @spec xchacha20_encrypt(binary(), binary(), binary()) :: binary()
  def xchacha20_encrypt(key, nonce, plaintext)
      when byte_size(key) == 32 and byte_size(nonce) == 24 and is_binary(plaintext) do
    xchacha20_xor(key, nonce, plaintext)
  end

  @doc """
  Decrypt XChaCha20 ciphertext. See `xchacha20_encrypt/3` for argument shape.

  XChaCha20 is a symmetric stream cipher — decryption is identical to
  encryption (XOR with the same keystream).
  """
  @spec xchacha20_decrypt(binary(), binary(), binary()) :: binary()
  def xchacha20_decrypt(key, nonce, ciphertext)
      when byte_size(key) == 32 and byte_size(nonce) == 24 and is_binary(ciphertext) do
    xchacha20_xor(key, nonce, ciphertext)
  end

  @doc "Generate a fresh 32-byte symmetric key seed."
  @spec gen_sym_seed() :: binary()
  def gen_sym_seed, do: :crypto.strong_rand_bytes(32)

  @doc "Generate a fresh 24-byte XChaCha20 nonce."
  @spec gen_nonce() :: binary()
  def gen_nonce, do: :crypto.strong_rand_bytes(24)

  @doc """
  Derive a per-file symmetric key from a snapshot's `sym_seed` and the file's
  bao_hash. Public-mode chunks are decrypted with this key.
  """
  @spec derive_file_key(binary(), binary()) :: binary()
  def derive_file_key(sym_seed, bao_hash_bytes)
      when byte_size(sym_seed) == 32 and is_binary(bao_hash_bytes) do
    hkdf_sha256(sym_seed, bao_hash_bytes, 32)
  end

  ## Base58 (Bitcoin alphabet)

  @b58_alphabet "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  @doc "Base58-encode raw bytes (Bitcoin alphabet)."
  @spec base58_encode(binary()) :: String.t()
  def base58_encode(<<>>), do: ""

  def base58_encode(bytes) when is_binary(bytes) do
    n = :binary.decode_unsigned(bytes)
    encode_b58_int(n, "")
  end

  defp encode_b58_int(0, acc), do: acc

  defp encode_b58_int(n, acc) do
    rem = rem(n, 58)
    char = :binary.part(@b58_alphabet, rem, 1)
    encode_b58_int(div(n, 58), char <> acc)
  end

  ## XChaCha20 internals

  import Bitwise

  # XChaCha20 = HChaCha20(key, nonce[0..15]) → subkey,
  # then ChaCha20(subkey, <<0::32, nonce[16..23]>>, plaintext)
  defp xchacha20_xor(key, nonce, data) do
    <<hn::binary-size(16), tail::binary-size(8)>> = nonce
    subkey = hchacha20(key, hn)
    # OTP :crypto.crypto_one_time(:chacha20) requires a 16-byte IV:
    # 4-byte little-endian block counter (0) + 12-byte stream nonce.
    # We use 4 zero bytes (counter=0) + 4 zero pad bytes + 8-byte tail.
    chacha_nonce = <<0::32, 0::32, tail::binary>>
    :crypto.crypto_one_time(:chacha20, subkey, chacha_nonce, data, true)
  end

  # HChaCha20 per draft-irtf-cfrg-xchacha §2.2.
  # Runs 20 ChaCha rounds on the initial state and returns the first and last
  # row of the result as a 32-byte subkey.
  defp hchacha20(key, nonce16) when byte_size(key) == 32 and byte_size(nonce16) == 16 do
    <<k0::32-little, k1::32-little, k2::32-little, k3::32-little, k4::32-little, k5::32-little,
      k6::32-little, k7::32-little>> = key

    <<n0::32-little, n1::32-little, n2::32-little, n3::32-little>> = nonce16

    # ChaCha20 magic constants ("expa", "nd 3", "2-by", "te k")
    s0 = 0x61707865
    s1 = 0x3320646E
    s2 = 0x79622D32
    s3 = 0x6B206574

    # Initial state rows:
    # row0: [s0, s1, s2, s3]
    # row1: [k0, k1, k2, k3]
    # row2: [k4, k5, k6, k7]
    # row3: [n0, n1, n2, n3]
    {a0, a1, a2, a3, _b0, _b1, _b2, _b3, _c0, _c1, _c2, _c3, d0, d1, d2, d3} =
      chacha20_rounds(
        s0,
        s1,
        s2,
        s3,
        k0,
        k1,
        k2,
        k3,
        k4,
        k5,
        k6,
        k7,
        n0,
        n1,
        n2,
        n3
      )

    # HChaCha20 output: first word-row (a0..a3) + last word-row (d0..d3),
    # WITHOUT adding the initial state (unlike ChaCha20 proper).
    <<a0::32-little, a1::32-little, a2::32-little, a3::32-little, d0::32-little, d1::32-little,
      d2::32-little, d3::32-little>>
  end

  defp chacha20_rounds(a0, a1, a2, a3, b0, b1, b2, b3, c0, c1, c2, c3, d0, d1, d2, d3) do
    # 20 rounds = 10 double-rounds (column then diagonal)
    Enum.reduce(1..10, {a0, a1, a2, a3, b0, b1, b2, b3, c0, c1, c2, c3, d0, d1, d2, d3}, fn _,
                                                                                            {a0,
                                                                                             a1,
                                                                                             a2,
                                                                                             a3,
                                                                                             b0,
                                                                                             b1,
                                                                                             b2,
                                                                                             b3,
                                                                                             c0,
                                                                                             c1,
                                                                                             c2,
                                                                                             c3,
                                                                                             d0,
                                                                                             d1,
                                                                                             d2,
                                                                                             d3} ->
      # Column round
      {a0, b0, c0, d0} = qr(a0, b0, c0, d0)
      {a1, b1, c1, d1} = qr(a1, b1, c1, d1)
      {a2, b2, c2, d2} = qr(a2, b2, c2, d2)
      {a3, b3, c3, d3} = qr(a3, b3, c3, d3)
      # Diagonal round
      {a0, b1, c2, d3} = qr(a0, b1, c2, d3)
      {a1, b2, c3, d0} = qr(a1, b2, c3, d0)
      {a2, b3, c0, d1} = qr(a2, b3, c0, d1)
      {a3, b0, c1, d2} = qr(a3, b0, c1, d2)
      {a0, a1, a2, a3, b0, b1, b2, b3, c0, c1, c2, c3, d0, d1, d2, d3}
    end)
  end

  @mask32 0xFFFFFFFF

  # ChaCha20 quarter-round
  defp qr(a, b, c, d) do
    a = band32(a + b)
    d = rotl32(bxor(d, a), 16)
    c = band32(c + d)
    b = rotl32(bxor(b, c), 12)
    a = band32(a + b)
    d = rotl32(bxor(d, a), 8)
    c = band32(c + d)
    b = rotl32(bxor(b, c), 7)
    {a, b, c, d}
  end

  defp band32(x), do: x &&& @mask32
  defp rotl32(x, n), do: band32(x <<< n ||| x >>> (32 - n))
end
