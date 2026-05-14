defmodule Mjolnir.Sites.ManifestTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Sites.Manifest
  alias Mjolnir.Sites.Manifest.Entry

  defp sample_manifest do
    %Manifest{
      version: 1,
      identikey_fp: "abc123",
      site_name: "blog",
      mode: :public,
      created_at: ~U[2026-05-13 12:00:00Z],
      sym_seed: :crypto.strong_rand_bytes(32),
      entries: [
        %Entry{
          path: "/index.html",
          content_type: "text/html; charset=utf-8",
          bao_hash: "deadbeef",
          ciphertext_size: 100,
          plaintext_size: 90,
          nonce: :crypto.strong_rand_bytes(24),
          wrapped_key: nil,
          content_encoding: nil
        }
      ],
      signatures: <<1, 2, 3>>
    }
  end

  test "serialize then parse round-trips" do
    m = sample_manifest()
    bytes = Manifest.serialize(m)
    assert {:ok, %Manifest{} = parsed} = Manifest.parse(bytes)
    assert parsed.version == m.version
    assert parsed.identikey_fp == m.identikey_fp
    assert parsed.site_name == m.site_name
    assert parsed.mode == :public
    assert parsed.sym_seed == m.sym_seed
    assert parsed.signatures == m.signatures
    [e] = parsed.entries
    [orig] = m.entries
    assert e.path == orig.path
    assert e.content_type == orig.content_type
    assert e.bao_hash == orig.bao_hash
    assert e.ciphertext_size == orig.ciphertext_size
    assert e.plaintext_size == orig.plaintext_size
    assert e.nonce == orig.nonce
  end

  test "lookup_entry finds by path" do
    m = sample_manifest()
    assert %Entry{path: "/index.html"} = Manifest.lookup_entry(m, "/index.html")
    assert nil == Manifest.lookup_entry(m, "/missing.html")
  end

  test "snapshot_hash is deterministic" do
    m = sample_manifest()
    bytes = Manifest.serialize(m)
    h1 = Manifest.snapshot_hash(bytes)
    h2 = Manifest.snapshot_hash(bytes)
    assert h1 == h2
    assert is_binary(h1)
    assert byte_size(h1) > 0
  end

  test "snapshot_hash differs when bytes differ" do
    a = Manifest.snapshot_hash("a")
    b = Manifest.snapshot_hash("b")
    refute a == b
  end
end
