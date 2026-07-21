# Cross-implementation check: does the Rust `mjolnir sites publish` client
# produce envelopes the Elixir Sites stack accepts?
#
# The Rust test `sites::tests::sites_crossimpl_fixtures` writes a keypair, a
# signed manifest, a signed HEAD record and the raw ciphertexts into a fixture
# directory. This script parses them with the real `Mjolnir.Sites` modules and
# verifies every property the server depends on:
#
#   1. The keypair file loads via `IdentiKey.keypair_from_json/1`.
#   2. The fingerprint Rust derived matches `IdentiKey.fingerprint/1`.
#   3. Manifest and HEAD parse, and re-serializing the parsed struct reproduces
#      the Rust bytes exactly — this is what `SecretStore.canonical_bytes_without_sig/2`
#      does before verifying, so any drift here breaks every signature.
#   4. Both signatures verify against the canonical signing bytes.
#   5. Each entry's ciphertext decrypts to the original file using a key derived
#      from the manifest's own `sym_seed`, and its `bao_hash` matches.
#
# Run it (mix is unusable in this checkout — Hex 2.5.1 vs Elixir 1.19.5 — so
# load the prebuilt beams directly):
#
#     cd native && MJ_SITES_FIXTURE_DIR=/tmp/mj-sites-fixtures \
#       cargo test -p mjolnir-client sites_crossimpl_fixtures
#     cd .. && elixir $(for d in _build/dev/lib/*/ebin; do printf -- "-pa %s " "$d"; done) \
#       scripts/sites_crossimpl_check.exs /tmp/mj-sites-fixtures

alias Mjolnir.Sites.{Crypto, HeadRecord, IdentiKey, Manifest, MultiSig}

dir =
  case System.argv() do
    [d | _] -> d
    [] -> raise "usage: sites_crossimpl_check.exs <fixture-dir>"
  end

read = fn name -> File.read!(Path.join(dir, name)) end

meta = Jason.decode!(read.("meta.json"))
manifest_bytes = read.("manifest.json")
head_bytes = read.("head.json")

failures = []

check = fn failures, label, result ->
  case result do
    :ok ->
      IO.puts("  ok    #{label}")
      failures

    {:error, why} ->
      IO.puts("  FAIL  #{label} — #{why}")
      [label | failures]
  end
end

IO.puts("Verifying Rust-produced Sites envelopes in #{dir}\n")

# 1 + 2 — keypair loads, fingerprint agrees.
{:ok, keypair} = IdentiKey.keypair_from_json(read.("keypair.json"))
pub = keypair.ed25519_public

failures =
  check.(failures, "keypair fingerprint matches Rust's", fn ->
    elixir_fp = IdentiKey.fingerprint(pub)

    if elixir_fp == meta["identikey_fp"],
      do: :ok,
      else: {:error, "elixir=#{elixir_fp} rust=#{meta["identikey_fp"]}"}
  end.())

# The public key must actually correspond to the stored secret, otherwise the
# signatures below would verify against a key the server never sees.
failures =
  check.(failures, "stored public key derives from the stored secret", fn ->
    derived = :crypto.generate_key(:eddsa, :ed25519, keypair.ed25519_secret) |> elem(0)
    if derived == pub, do: :ok, else: {:error, "public key does not match secret"}
  end.())

# 3 — round-trip stability. This is the property the signature verifier relies on.
failures =
  check.(failures, "manifest survives parse → serialize byte-identically", fn ->
    {:ok, manifest} = Manifest.parse(manifest_bytes)
    reserialized = Manifest.serialize(manifest)

    if reserialized == manifest_bytes,
      do: :ok,
      else: {:error, "rust=#{inspect(manifest_bytes)}\n        elixir=#{inspect(reserialized)}"}
  end.())

failures =
  check.(failures, "HEAD survives parse → serialize byte-identically", fn ->
    {:ok, head} = HeadRecord.parse(head_bytes)
    reserialized = HeadRecord.serialize(head)

    if reserialized == head_bytes,
      do: :ok,
      else: {:error, "rust=#{inspect(head_bytes)}\n        elixir=#{inspect(reserialized)}"}
  end.())

# 4 — signatures verify over the canonical (signature-cleared) bytes.
{:ok, manifest} = Manifest.parse(manifest_bytes)
{:ok, head} = HeadRecord.parse(head_bytes)

failures =
  check.(failures, "manifest signature verifies", fn ->
    signing_bytes = Manifest.canonical_signing_bytes(manifest)

    if IdentiKey.verify(pub, signing_bytes, manifest.signatures),
      do: :ok,
      else: {:error, "ED25519 verify returned false"}
  end.())

failures =
  check.(failures, "HEAD signature verifies", fn ->
    signing_bytes = HeadRecord.canonical_signing_bytes(head)

    if IdentiKey.verify(pub, signing_bytes, head.signature),
      do: :ok,
      else: {:error, "ED25519 verify returned false"}
  end.())

# The signature must be carried in the MultiSig object shape, not the legacy
# bare-base64 form, so the ML-DSA leg can be added later without a migration.
failures =
  check.(failures, "signatures use the MultiSig object wire shape", fn ->
    raw = Jason.decode!(manifest_bytes)

    case raw["signatures"] do
      %{"ed25519" => b64} when is_binary(b64) ->
        case MultiSig.from_field(raw["signatures"]) do
          %MultiSig{ed25519: sig} when byte_size(sig) == 64 -> :ok
          other -> {:error, "unexpected MultiSig: #{inspect(other)}"}
        end

      other ->
        {:error, "expected an object, got #{inspect(other)}"}
    end
  end.())

# 5 — the payload itself: each chunk decrypts back to the file on disk.
failures =
  check.(failures, "every entry decrypts to its original file", fn ->
    sym_seed = manifest.sym_seed
    site_root = meta["site_root"]

    Enum.reduce_while(manifest.entries, :ok, fn entry, :ok ->
      ciphertext = File.read!(Path.join([dir, "chunks", entry.bao_hash]))
      expected = File.read!(Path.join(site_root, String.trim_leading(entry.path, "/")))

      sym_key = Crypto.hkdf_sha256(sym_seed, entry.path, 32)
      plaintext = Crypto.xchacha20_decrypt(sym_key, entry.nonce, ciphertext)

      cond do
        Crypto.blake3_hash_base58(ciphertext) != entry.bao_hash ->
          {:halt, {:error, "#{entry.path}: bao_hash mismatch"}}

        byte_size(ciphertext) != entry.ciphertext_size ->
          {:halt, {:error, "#{entry.path}: ciphertext_size mismatch"}}

        byte_size(plaintext) != entry.plaintext_size ->
          {:halt, {:error, "#{entry.path}: plaintext_size mismatch"}}

        plaintext != expected ->
          {:halt, {:error, "#{entry.path}: decrypted #{inspect(plaintext)}"}}

        true ->
          {:cont, :ok}
      end
    end)
  end.())

# The snapshot hash the server would compute over the Rust bytes must match the
# one Rust predicted for the HEAD record it signed.
failures =
  check.(failures, "snapshot hash agrees across implementations", fn ->
    elixir_hash = Manifest.snapshot_hash(manifest_bytes)

    cond do
      elixir_hash != meta["snapshot_hash"] ->
        {:error, "elixir=#{elixir_hash} rust=#{meta["snapshot_hash"]}"}

      head.snapshot_hash != elixir_hash ->
        {:error, "HEAD points at #{head.snapshot_hash}, manifest hashes to #{elixir_hash}"}

      true ->
        :ok
    end
  end.())

IO.puts("")

if failures == [] do
  IO.puts("All cross-implementation checks passed (#{length(manifest.entries)} entries).")
else
  IO.puts("#{length(failures)} check(s) FAILED: #{inspect(Enum.reverse(failures))}")
  System.halt(1)
end
