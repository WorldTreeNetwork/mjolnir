defmodule Mjolnir.Sites.CryptoSeamTest do
  @moduledoc """
  End-to-end coverage of the IdentiKey Sites crypto seam:

    * manifest + HEAD sign → verify round-trips,
    * tampered bodies are rejected on verification,
    * the on-wire signature is the forward-compatible MultiSig object shape,
    * public-mode encrypt(publisher) → decrypt(server convention) round-trips.

  The SecretStore-level accept-path verification and the full publish→serve
  plaintext round-trip are covered in `secret_store_signature_test.exs` and
  `mjolnir.sites.publish_test.exs` respectively; this file isolates the record
  signing and symmetric-key derivation conventions.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias Mjolnir.Sites.{Crypto, HeadRecord, IdentiKey, Manifest, MultiSig}
  alias Mjolnir.Sites.Manifest.Entry

  setup do
    kp = IdentiKey.gen_keypair()
    {:ok, kp: kp, fp: IdentiKey.fingerprint(kp)}
  end

  defp build_manifest(fp, seed) do
    %Manifest{
      version: 1,
      identikey_fp: fp,
      site_name: "blog",
      mode: :public,
      created_at: ~U[2026-06-22 00:00:00Z],
      sym_seed: seed,
      signatures: nil,
      entries: [
        %Entry{
          path: "/index.html",
          content_type: "text/html; charset=utf-8",
          bao_hash: "deadbeef",
          ciphertext_size: 5,
          plaintext_size: 5,
          nonce: :crypto.strong_rand_bytes(24),
          wrapped_key: nil,
          content_encoding: nil
        }
      ]
    }
  end

  defp build_head(fp) do
    %HeadRecord{
      version: 1,
      identikey_fp: fp,
      site_name: "blog",
      snapshot_hash: "snap123",
      sequence: 1,
      created_at: ~U[2026-06-22 00:00:00Z],
      signature: nil
    }
  end

  describe "manifest sign → verify" do
    test "round-trips through serialize/parse and verifies", %{kp: kp, fp: fp} do
      manifest = build_manifest(fp, :crypto.strong_rand_bytes(32))
      signing_bytes = Manifest.canonical_signing_bytes(manifest)
      sig = IdentiKey.sign(kp, signing_bytes)
      bytes = %{manifest | signatures: sig} |> Manifest.serialize()

      {:ok, parsed} = Manifest.parse(bytes)
      assert parsed.signatures == sig
      # canonical bytes must be stable across the wire round-trip
      assert Manifest.canonical_signing_bytes(parsed) == signing_bytes

      assert IdentiKey.verify(
               kp.ed25519_public,
               Manifest.canonical_signing_bytes(parsed),
               parsed.signatures
             )
    end

    test "tampered manifest body fails verification", %{kp: kp, fp: fp} do
      manifest = build_manifest(fp, :crypto.strong_rand_bytes(32))
      sig = IdentiKey.sign(kp, Manifest.canonical_signing_bytes(manifest))

      tampered = %{manifest | site_name: "evil", signatures: sig}

      refute IdentiKey.verify(
               kp.ed25519_public,
               Manifest.canonical_signing_bytes(tampered),
               sig
             )
    end

    test "signature is serialized as a MultiSig object, not a bare string", %{kp: kp, fp: fp} do
      manifest = build_manifest(fp, :crypto.strong_rand_bytes(32))
      sig = IdentiKey.sign(kp, Manifest.canonical_signing_bytes(manifest))
      bytes = %{manifest | signatures: sig} |> Manifest.serialize()

      field = Jason.decode!(bytes)["signatures"]
      assert is_map(field)
      assert Map.has_key?(field, "ed25519")
      assert %MultiSig{ed25519: ^sig} = MultiSig.from_field(field)
    end

    test "unsigned manifest serializes the signature field as null", %{fp: fp} do
      manifest = build_manifest(fp, :crypto.strong_rand_bytes(32))
      bytes = Manifest.serialize(manifest)
      assert Jason.decode!(bytes)["signatures"] == nil
    end
  end

  describe "HEAD sign → verify" do
    test "round-trips through serialize/parse and verifies", %{kp: kp, fp: fp} do
      head = build_head(fp)
      signing_bytes = HeadRecord.canonical_signing_bytes(head)
      sig = IdentiKey.sign(kp, signing_bytes)
      bytes = %{head | signature: sig} |> HeadRecord.serialize()

      {:ok, parsed} = HeadRecord.parse(bytes)
      assert parsed.signature == sig
      assert HeadRecord.canonical_signing_bytes(parsed) == signing_bytes

      assert IdentiKey.verify(
               kp.ed25519_public,
               HeadRecord.canonical_signing_bytes(parsed),
               parsed.signature
             )
    end

    test "tampered HEAD body (snapshot_hash) fails verification", %{kp: kp, fp: fp} do
      head = build_head(fp)
      sig = IdentiKey.sign(kp, HeadRecord.canonical_signing_bytes(head))

      tampered = %{head | snapshot_hash: "evilsnap", signature: sig}

      refute IdentiKey.verify(
               kp.ed25519_public,
               HeadRecord.canonical_signing_bytes(tampered),
               sig
             )
    end

    test "flipping a byte in the signature fails verification", %{kp: kp, fp: fp} do
      head = build_head(fp)
      sig = IdentiKey.sign(kp, HeadRecord.canonical_signing_bytes(head))
      <<first, rest::binary>> = sig
      bad = <<bxor(first, 0xFF), rest::binary>>
      refute IdentiKey.verify(kp.ed25519_public, HeadRecord.canonical_signing_bytes(head), bad)
    end
  end

  describe "public-mode encrypt → decrypt convention" do
    test "publisher encryption decrypts back to original plaintext" do
      seed = Crypto.gen_sym_seed()
      path = "/index.html"
      plaintext = "<html>hello world</html>"

      # Publisher side: sym_key = HKDF(sym_seed, info=path, 32)
      sym_key = Crypto.hkdf_sha256(seed, path, 32)
      nonce = Crypto.gen_nonce()
      ciphertext = Crypto.xchacha20_encrypt(sym_key, nonce, plaintext)

      refute ciphertext == plaintext

      # Server side: identical derivation, then decrypt
      server_key = Crypto.hkdf_sha256(seed, path, 32)
      assert server_key == sym_key
      assert Crypto.xchacha20_decrypt(server_key, nonce, ciphertext) == plaintext
    end

    test "wrong path derives a different key and fails to recover plaintext" do
      seed = Crypto.gen_sym_seed()
      nonce = Crypto.gen_nonce()
      plaintext = "secret"

      key = Crypto.hkdf_sha256(seed, "/right.html", 32)
      ciphertext = Crypto.xchacha20_encrypt(key, nonce, plaintext)

      wrong_key = Crypto.hkdf_sha256(seed, "/wrong.html", 32)
      refute Crypto.xchacha20_decrypt(wrong_key, nonce, ciphertext) == plaintext
    end
  end
end
