defmodule Mjolnir.Sites.Publisher do
  @moduledoc """
  Publish-side logic for IdentiKey Sites (public mode, Phase 1).

  This module is split into two layers so the pure snapshot-building path can
  be tested without a live HTTP server:

  - `build_snapshot/4` — walk a local directory, encrypt files, build a
    `Manifest` and a chunk map. Pure (no I/O beyond reading input files).
  - `publish/5` — call `build_snapshot/4` then drive the HTTP publish protocol
    against a Mjolnir host.

  ## Key-derivation convention (Phase 1)

  Per-file symmetric keys are derived as:

      sym_key = HKDF-SHA256(sym_seed, info=entry_path, length=32)

  Using the file path (rather than the ciphertext hash) as the HKDF info
  avoids the chicken-and-egg problem where the ciphertext hash is not known
  until after encryption, but encryption needs the key. Both this module and
  `Mjolnir.Sites.Server.decrypt_public/4` use the same derivation.

  ## Signatures

  When a `:keypair` is supplied, the canonical manifest body and HEAD/alias
  record bodies are signed with the IdentiKey's ED25519 secret key (via
  `Mjolnir.Sites.IdentiKey`). The signature is carried internally as a raw
  ED25519 binary and serialized on the wire as a forward-compatible
  `Mjolnir.Sites.MultiSig` object (`{"ed25519": "<base64>"}`), so the eventual
  ML-DSA-87 leg is purely additive. When `:keypair` is `nil` the record is left
  unsigned (the signature field serializes to `null`).
  """

  require Logger

  alias Mjolnir.Sites.{AliasRecord, Crypto, HeadRecord, IdentiKey, Manifest}
  alias Mjolnir.Sites.Manifest.Entry

  @type chunk_map :: %{String.t() => %{ciphertext: binary(), outboard: binary()}}

  # ---------------------------------------------------------------------------
  # Pure build path
  # ---------------------------------------------------------------------------

  @doc """
  Walk `dir`, encrypt every file, build a `Manifest` and a chunk map.

  Returns `{manifest, chunks}` where `chunks` is a map from `bao_hash` to
  `%{ciphertext: binary(), outboard: binary()}`.

  Options:
  - `:sym_seed` — override the per-snapshot seed (32 bytes). Useful in tests.
  - `:keypair`  — `Mjolnir.Sites.IdentiKey.keypair()` used to sign the manifest.
    When `nil` (default) the `signatures` field is left as `<<>>` (unsigned).
  """
  @spec build_snapshot(String.t(), String.t(), String.t(), keyword()) ::
          {Manifest.t(), chunk_map()}
  def build_snapshot(dir, identikey_fp, site_name, opts \\ []) do
    sym_seed = Keyword.get(opts, :sym_seed, Crypto.gen_sym_seed())
    keypair = Keyword.get(opts, :keypair, nil)

    files = collect_files(dir)

    {entries, chunks} =
      Enum.reduce(files, {[], %{}}, fn {abs_path, rel_path}, {entries_acc, chunks_acc} ->
        plaintext = File.read!(abs_path)
        nonce = Crypto.gen_nonce()
        sym_key = Crypto.hkdf_sha256(sym_seed, rel_path, 32)
        ciphertext = Crypto.xchacha20_encrypt(sym_key, nonce, plaintext)
        bao_hash = Crypto.blake3_hash_base58(ciphertext)

        entry = %Entry{
          path: rel_path,
          content_type: mime_of(rel_path),
          bao_hash: bao_hash,
          ciphertext_size: byte_size(ciphertext),
          plaintext_size: byte_size(plaintext),
          nonce: nonce,
          wrapped_key: nil,
          content_encoding: nil
        }

        chunk = %{ciphertext: ciphertext, outboard: <<>>}
        {[entry | entries_acc], Map.put(chunks_acc, bao_hash, chunk)}
      end)

    unsigned = %Manifest{
      version: 1,
      identikey_fp: identikey_fp,
      site_name: site_name,
      mode: :public,
      created_at: DateTime.utc_now() |> DateTime.truncate(:second),
      sym_seed: sym_seed,
      signatures: nil,
      entries: Enum.reverse(entries)
    }

    manifest = sign_manifest(unsigned, keypair)

    {manifest, chunks}
  end

  defp sign_manifest(manifest, nil), do: %{manifest | signatures: <<>>}

  defp sign_manifest(manifest, keypair) do
    signing_bytes = Manifest.canonical_signing_bytes(manifest)
    sig = IdentiKey.sign(keypair, signing_bytes)
    %{manifest | signatures: sig}
  end

  defp sign_head(head, nil), do: %{head | signature: <<>>}

  defp sign_head(head, keypair) do
    signing_bytes = HeadRecord.canonical_signing_bytes(head)
    sig = IdentiKey.sign(keypair, signing_bytes)
    %{head | signature: sig}
  end

  # ---------------------------------------------------------------------------
  # HTTP publish path
  # ---------------------------------------------------------------------------

  @doc """
  Full publish flow: build snapshot, POST manifest, upload missing chunks, POST HEAD.

  Options:
  - `:sequence` — HEAD sequence number (default 1)
  - `:sym_seed`  — override per-snapshot seed (useful in tests)

  Returns `{:ok, %{snapshot_hash: hash, sequence: seq}}` or `{:error, reason}`.
  """
  @spec publish(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{snapshot_hash: String.t(), sequence: non_neg_integer()}} | {:error, term()}
  def publish(dir, identikey_fp, site_name, base_url, opts \\ []) do
    sequence = Keyword.get(opts, :sequence, 1)
    keypair = Keyword.get(opts, :keypair, nil)

    {manifest, chunks} = build_snapshot(dir, identikey_fp, site_name, opts)
    manifest_bytes = Manifest.serialize(manifest)

    with :ok <- maybe_register_identity(base_url, identikey_fp, keypair),
         {:ok, snapshot_hash, missing} <-
           post_snapshot(base_url, identikey_fp, site_name, manifest_bytes),
         :ok <- upload_missing_chunks(base_url, missing, chunks),
         {:ok, _seq} <-
           post_head(base_url, identikey_fp, site_name, snapshot_hash, sequence, keypair) do
      {:ok, %{snapshot_hash: snapshot_hash, sequence: sequence}}
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP helpers
  # ---------------------------------------------------------------------------

  # Deposit the self-authenticating identity/pubkey record so the server can
  # verify the signed HEAD record that follows. Idempotent — re-registering the
  # same key is a no-op. Skipped entirely for unsigned publishes (no keypair).
  defp maybe_register_identity(_base_url, _fp, nil), do: :ok

  defp maybe_register_identity(base_url, fp, %{ed25519_public: pub}) do
    body = Jason.encode!(%{"pubkey" => Base.encode64(pub)})
    url = "#{base_url}/api/sites/#{fp}/identity"

    case Req.put(url, body: body, headers: [{"content-type", "application/json"}]) do
      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:identity_register_failed, status, body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp post_snapshot(base_url, fp, name, manifest_bytes) do
    url = "#{base_url}/api/sites/#{fp}/#{name}/snapshot"

    case Req.post(url,
           body: manifest_bytes,
           headers: [{"content-type", "application/octet-stream"}]
         ) do
      {:ok, %{status: 201, body: body}} ->
        snapshot_hash = Map.fetch!(body, "snapshot_hash")
        missing = Map.get(body, "missing_chunks", [])
        {:ok, snapshot_hash, missing}

      {:ok, %{status: status, body: body}} ->
        {:error, {:snapshot_upload_failed, status, body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp upload_missing_chunks(base_url, missing, chunks) do
    Enum.reduce_while(missing, :ok, fn bao_hash, :ok ->
      case Map.fetch(chunks, bao_hash) do
        {:ok, %{ciphertext: ct, outboard: ob}} ->
          case put_chunk(base_url, bao_hash, ct, ob) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end

        :error ->
          {:halt, {:error, {:chunk_not_in_snapshot, bao_hash}}}
      end
    end)
  end

  defp put_chunk(base_url, bao_hash, ciphertext, outboard) do
    url = "#{base_url}/api/sites/blob/#{bao_hash}"

    framed =
      <<byte_size(ciphertext)::big-unsigned-64, ciphertext::binary,
        byte_size(outboard)::big-unsigned-64, outboard::binary>>

    case Req.put(url,
           body: framed,
           headers: [{"content-type", "application/octet-stream"}]
         ) do
      {:ok, %{status: 201}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:chunk_upload_failed, bao_hash, status, body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp post_head(base_url, fp, name, snapshot_hash, sequence, keypair) do
    unsigned_head = %HeadRecord{
      version: 1,
      identikey_fp: fp,
      site_name: name,
      snapshot_hash: snapshot_hash,
      sequence: sequence,
      created_at: DateTime.utc_now() |> DateTime.truncate(:second),
      signature: nil
    }

    head = sign_head(unsigned_head, keypair)

    url = "#{base_url}/api/sites/#{fp}/#{name}/head"
    head_bytes = HeadRecord.serialize(head)

    case Req.post(url,
           body: head_bytes,
           headers: [{"content-type", "application/octet-stream"}]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Map.fetch!(body, "sequence")}

      {:ok, %{status: status, body: body}} ->
        {:error, {:head_update_failed, status, body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Alias publish/remove
  # ---------------------------------------------------------------------------

  @doc """
  Build a signed alias record envelope as binary bytes.

  Signs the record with `keypair` and returns the serialized bytes ready to be
  PUT to `<base_url>/api/sites/<fp>/<site>/aliases/<fqdn>`.
  """
  @spec build_alias(IdentiKey.keypair(), String.t(), String.t(), String.t(), pos_integer()) ::
          binary()
  def build_alias(keypair, fp, site_name, fqdn, sequence \\ 1) do
    record = %AliasRecord{
      version: 1,
      identikey_fp: fp,
      site_name: site_name,
      fqdn: fqdn,
      sequence: sequence,
      created_at: DateTime.utc_now() |> DateTime.truncate(:second),
      signature: nil
    }

    signing_bytes = AliasRecord.canonical_signing_bytes(record)
    sig = IdentiKey.sign(keypair, signing_bytes)
    AliasRecord.serialize(%{record | signature: sig})
  end

  @doc """
  Publish a custom-domain alias by PUT-ing a signed alias record to the server.

  Options:
  - `:sequence` — alias sequence number (default 1)

  Returns `{:ok, map()}` on 201, `{:error, term()}` otherwise.
  """
  @spec publish_alias(
          IdentiKey.keypair(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def publish_alias(keypair, fp, site_name, fqdn, base_url, opts \\ []) do
    sequence = Keyword.get(opts, :sequence, 1)
    alias_bytes = build_alias(keypair, fp, site_name, fqdn, sequence)
    url = "#{base_url}/api/sites/#{fp}/#{site_name}/aliases/#{fqdn}"

    case Req.put(url,
           body: alias_bytes,
           headers: [{"content-type", "application/octet-stream"}]
         ) do
      {:ok, %{status: 201, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:alias_publish_failed, status, body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Remove a custom-domain alias by DELETE-ing a signed tombstone record to the server.

  The tombstone is a fresh signed alias record with a higher sequence number,
  proving ownership authority.

  Options:
  - `:sequence` — tombstone sequence number (default: current unix milliseconds
    to guarantee it's higher than any previously published alias)

  Returns `:ok` on 204, `{:error, term()}` otherwise.
  """
  @spec remove_alias(
          IdentiKey.keypair(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def remove_alias(keypair, fp, site_name, fqdn, base_url, opts \\ []) do
    sequence = Keyword.get(opts, :sequence, :erlang.system_time(:millisecond))
    tombstone_bytes = build_alias(keypair, fp, site_name, fqdn, sequence)
    url = "#{base_url}/api/sites/#{fp}/#{site_name}/aliases/#{fqdn}"

    case Req.delete(url,
           body: tombstone_bytes,
           headers: [{"content-type", "application/octet-stream"}]
         ) do
      {:ok, %{status: 204}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:alias_remove_failed, status, body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # File system helpers
  # ---------------------------------------------------------------------------

  # Walk `dir` recursively and return `[{abs_path, rel_path}]` for all regular
  # files, where `rel_path` is the path relative to `dir` with a leading `/`.
  defp collect_files(dir) do
    dir
    |> Path.expand()
    |> do_collect(dir |> Path.expand())
    |> Enum.sort_by(&elem(&1, 1))
  end

  defp do_collect(path, base) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn name ->
          full = Path.join(path, name)

          # lstat, not stat: `stat` follows symlinks, so a `build/creds ->
          # ~/.ssh/id_ed25519` in the directory being published would be
          # dereferenced and its *contents* copied into the snapshot. That is a
          # foot-gun for whoever runs the publish (they ship their own secret),
          # not a remote attack — but it is silent, so skip symlinks and say so.
          case File.lstat(full) do
            {:ok, %{type: :regular}} ->
              rel = "/" <> Path.relative_to(full, base)
              [{full, rel}]

            {:ok, %{type: :directory}} ->
              do_collect(full, base)

            {:ok, %{type: :symlink}} ->
              Logger.warning("Sites.Publisher: skipping symlink #{full}")
              []

            _ ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # MIME sniffing
  # ---------------------------------------------------------------------------

  @doc false
  @spec mime_of(String.t()) :: String.t()
  def mime_of(path) do
    case path |> Path.extname() |> String.downcase() do
      ".html" -> "text/html; charset=utf-8"
      ".htm" -> "text/html; charset=utf-8"
      ".css" -> "text/css; charset=utf-8"
      ".js" -> "application/javascript"
      ".mjs" -> "application/javascript"
      ".json" -> "application/json"
      ".map" -> "application/json"
      ".xml" -> "application/xml"
      ".txt" -> "text/plain; charset=utf-8"
      ".svg" -> "image/svg+xml"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".avif" -> "image/avif"
      ".ico" -> "image/x-icon"
      ".woff" -> "font/woff"
      ".woff2" -> "font/woff2"
      ".ttf" -> "font/ttf"
      ".wasm" -> "application/wasm"
      _ -> "application/octet-stream"
    end
  end
end
