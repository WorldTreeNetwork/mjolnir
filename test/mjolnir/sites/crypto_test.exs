defmodule Mjolnir.Sites.CryptoTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Sites.Crypto

  ## Blake3

  test "blake3_hash returns 32 bytes" do
    assert byte_size(Crypto.blake3_hash("hello")) == 32
  end

  @tag :skip
  test "blake3_hash empty-string known-answer vector (re-enable when real Blake3 lands)" do
    # Official Blake3 test vector: hash of empty bytes.
    # SKIPPED until the SHA-256 placeholder in Sites.Crypto is replaced with a
    # real Blake3 binding (waiting on a working rustler/Rust toolchain combo or
    # the recrypt Rust integration).
    expected = Base.decode16!("AF1349B9F5F9A1A6A0404DEA36DCC9499BCB25C9ADC112B7CC9A93CAE41F3262",
                              case: :upper)
    assert Crypto.blake3_hash("") == expected
  end

  test "blake3_hash deterministic" do
    assert Crypto.blake3_hash("abc") == Crypto.blake3_hash("abc")
  end

  test "blake3_hash different inputs produce different digests" do
    refute Crypto.blake3_hash("foo") == Crypto.blake3_hash("bar")
  end

  test "blake3_hash_base58 returns non-empty string for non-empty input" do
    result = Crypto.blake3_hash_base58("hello")
    assert is_binary(result) and result != ""
  end

  test "blake3_hash_base58 is deterministic" do
    assert Crypto.blake3_hash_base58("abc") == Crypto.blake3_hash_base58("abc")
  end

  ## XChaCha20

  test "xchacha20 encrypt-then-decrypt round-trip" do
    key = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(24)
    plaintext = "hello, xchacha20 world!"
    ciphertext = Crypto.xchacha20_encrypt(key, nonce, plaintext)
    assert Crypto.xchacha20_decrypt(key, nonce, ciphertext) == plaintext
  end

  test "xchacha20 ciphertext has same length as plaintext" do
    key = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(24)
    plaintext = "short"
    ciphertext = Crypto.xchacha20_encrypt(key, nonce, plaintext)
    assert byte_size(ciphertext) == byte_size(plaintext)
  end

  test "xchacha20 different keys produce different ciphertext" do
    key1 = :crypto.strong_rand_bytes(32)
    key2 = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(24)
    plaintext = "same plaintext"
    refute Crypto.xchacha20_encrypt(key1, nonce, plaintext) ==
             Crypto.xchacha20_encrypt(key2, nonce, plaintext)
  end

  test "xchacha20 different nonces produce different ciphertext" do
    key = :crypto.strong_rand_bytes(32)
    nonce1 = :crypto.strong_rand_bytes(24)
    nonce2 = :crypto.strong_rand_bytes(24)
    plaintext = "same plaintext"
    refute Crypto.xchacha20_encrypt(key, nonce1, plaintext) ==
             Crypto.xchacha20_encrypt(key, nonce2, plaintext)
  end

  test "xchacha20 encrypt of empty binary returns empty binary" do
    key = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(24)
    assert Crypto.xchacha20_encrypt(key, nonce, "") == ""
  end

  test "xchacha20 is symmetric (encrypt == decrypt)" do
    key = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(24)
    data = "symmetric"
    assert Crypto.xchacha20_encrypt(key, nonce, data) ==
             Crypto.xchacha20_decrypt(key, nonce, data)
  end

  ## HKDF

  test "hkdf_sha256 is deterministic" do
    ikm = "input-key-material"
    info = "context"
    assert Crypto.hkdf_sha256(ikm, info, 32) == Crypto.hkdf_sha256(ikm, info, 32)
  end

  test "hkdf_sha256 different info produces different output" do
    ikm = "same-key"
    refute Crypto.hkdf_sha256(ikm, "ctx-a", 32) == Crypto.hkdf_sha256(ikm, "ctx-b", 32)
  end

  test "hkdf_sha256 returns requested byte length" do
    assert byte_size(Crypto.hkdf_sha256("k", "i", 16)) == 16
    assert byte_size(Crypto.hkdf_sha256("k", "i", 64)) == 64
  end

  ## derive_file_key

  test "derive_file_key returns 32 bytes" do
    seed = :crypto.strong_rand_bytes(32)
    bao_hash = Crypto.blake3_hash("some content")
    assert byte_size(Crypto.derive_file_key(seed, bao_hash)) == 32
  end

  test "derive_file_key is deterministic" do
    seed = :crypto.strong_rand_bytes(32)
    bao_hash = Crypto.blake3_hash("content")
    assert Crypto.derive_file_key(seed, bao_hash) == Crypto.derive_file_key(seed, bao_hash)
  end

  test "derive_file_key different seeds produce different keys" do
    seed1 = :crypto.strong_rand_bytes(32)
    seed2 = :crypto.strong_rand_bytes(32)
    bao_hash = Crypto.blake3_hash("content")
    refute Crypto.derive_file_key(seed1, bao_hash) == Crypto.derive_file_key(seed2, bao_hash)
  end
end
