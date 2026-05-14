defmodule Mjolnir.SecretStoreSignatureTest do
  @moduledoc """
  Tests for SecretStore's real ED25519 verification logic, including the
  identity/pubkey bootstrap protocol.
  """
  use ExUnit.Case, async: false

  import Bitwise
  alias Mjolnir.SecretStore
  alias Mjolnir.Sites.{HeadRecord, IdentiKey, Manifest}
  alias Mjolnir.Sites.Manifest.Entry

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("mjolnir-ss-sig-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    original = Application.get_env(:mjolnir, :secret_store_root)
    Application.put_env(:mjolnir, :secret_store_root, tmp)

    on_exit(fn ->
      Application.put_env(:mjolnir, :secret_store_root, original)
      File.rm_rf!(tmp)
    end)

    keypair = IdentiKey.gen_keypair()
    fp = IdentiKey.fingerprint(keypair)

    {:ok, keypair: keypair, fp: fp}
  end

  # ---------------------------------------------------------------------------
  # Bootstrap helpers
  # ---------------------------------------------------------------------------

  defp identity_record(keypair) do
    Jason.encode!(%{
      "pubkey" => Base.encode64(keypair.ed25519_public)
    })
  end

  defp register_identity(keypair, fp) do
    :ok = SecretStore.put(fp, "identity/pubkey", identity_record(keypair))
  end

  defp sample_head(fp, snapshot_hash \\ "deadbeef", sequence \\ 1) do
    %HeadRecord{
      version: 1,
      identikey_fp: fp,
      site_name: "blog",
      snapshot_hash: snapshot_hash,
      sequence: sequence,
      created_at: ~U[2026-05-13 12:00:00Z],
      signature: nil
    }
  end

  defp signed_head(keypair, head) do
    signing_bytes = HeadRecord.canonical_signing_bytes(head)
    sig = IdentiKey.sign(keypair, signing_bytes)
    %{head | signature: sig} |> HeadRecord.serialize()
  end

  defp sample_manifest(fp) do
    %Manifest{
      version: 1,
      identikey_fp: fp,
      site_name: "blog",
      mode: :public,
      created_at: ~U[2026-05-13 12:00:00Z],
      sym_seed: :crypto.strong_rand_bytes(32),
      signatures: nil,
      entries: [
        %Entry{
          path: "/index.html",
          content_type: "text/html; charset=utf-8",
          bao_hash: "deadbeef",
          ciphertext_size: 11,
          plaintext_size: 11,
          nonce: :crypto.strong_rand_bytes(24),
          wrapped_key: nil,
          content_encoding: nil
        }
      ]
    }
  end

  defp signed_manifest(keypair, manifest) do
    signing_bytes = Manifest.canonical_signing_bytes(manifest)
    sig = IdentiKey.sign(keypair, signing_bytes)
    %{manifest | signatures: sig} |> Manifest.serialize()
  end

  # ---------------------------------------------------------------------------
  # Bootstrap tests
  # ---------------------------------------------------------------------------

  test "cannot put any record without first registering identity/pubkey", %{keypair: kp, fp: fp} do
    head = sample_head(fp)
    bytes = signed_head(kp, head)
    assert {:error, :identity_not_registered} = SecretStore.put(fp, "sites/blog/HEAD", bytes)
  end

  test "identity/pubkey bootstrap accepts a record whose pubkey matches the fp", %{keypair: kp, fp: fp} do
    assert :ok = SecretStore.put(fp, "identity/pubkey", identity_record(kp))
  end

  test "bootstrap rejects when pubkey fingerprint does not match fp", %{keypair: kp} do
    wrong_kp = IdentiKey.gen_keypair()
    wrong_fp = IdentiKey.fingerprint(wrong_kp)
    # identity record embeds kp.pubkey but we claim wrong_fp's keyspace
    assert {:error, :fingerprint_mismatch} =
             SecretStore.put(wrong_fp, "identity/pubkey", identity_record(kp))
  end

  test "empty envelope is always rejected", %{fp: fp} do
    assert {:error, :empty_envelope} = SecretStore.put(fp, "identity/pubkey", "")
  end

  # ---------------------------------------------------------------------------
  # Signed record tests (after bootstrap)
  # ---------------------------------------------------------------------------

  test "signed HEAD record is accepted after bootstrap", %{keypair: kp, fp: fp} do
    register_identity(kp, fp)
    head = sample_head(fp)
    bytes = signed_head(kp, head)
    assert :ok = SecretStore.put(fp, "sites/blog/HEAD", bytes)
    assert {:ok, ^bytes} = SecretStore.get(fp, "sites/blog/HEAD")
  end

  test "signed manifest is accepted after bootstrap", %{keypair: kp, fp: fp} do
    register_identity(kp, fp)
    manifest = sample_manifest(fp)
    bytes = signed_manifest(kp, manifest)
    assert :ok = SecretStore.put(fp, "sites/blog/manifest", bytes)
    assert {:ok, ^bytes} = SecretStore.get(fp, "sites/blog/manifest")
  end

  test "tampering with signed HEAD bytes breaks verification", %{keypair: kp, fp: fp} do
    register_identity(kp, fp)
    head = sample_head(fp)
    bytes = signed_head(kp, head)
    # Flip a byte in the middle of the body to corrupt it
    mid = div(byte_size(bytes), 2)
    <<pre::binary-size(mid), byte, rest::binary>> = bytes
    tampered = <<pre::binary, bxor(byte, 0x01), rest::binary>>
    # Tampered bytes may fail JSON parsing or signature verification
    result = SecretStore.put(fp, "sites/blog/HEAD", tampered)
    assert result != :ok
  end

  test "record signed by a different keypair is rejected", %{keypair: kp, fp: fp} do
    register_identity(kp, fp)
    wrong_kp = IdentiKey.gen_keypair()
    head = sample_head(fp)
    bytes = signed_head(wrong_kp, head)
    assert {:error, :bad_signature} = SecretStore.put(fp, "sites/blog/HEAD", bytes)
  end

  test "monotonic: second HEAD with higher sequence accepted", %{keypair: kp, fp: fp} do
    register_identity(kp, fp)
    h1 = sample_head(fp, "hash1", 1)
    h2 = sample_head(fp, "hash2", 2)
    assert :ok = SecretStore.put(fp, "sites/blog/HEAD", signed_head(kp, h1))
    assert :ok = SecretStore.put(fp, "sites/blog/HEAD", signed_head(kp, h2))
  end
end
