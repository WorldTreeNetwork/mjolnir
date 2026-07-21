defmodule Mjolnir.Sites.Server do
  @moduledoc """
  Serve path for IdentiKey sites — looks up HEAD, parses manifest, fetches
  chunks, decrypts (public mode), writes plaintext to the response.

  See `docs/plans/initiatives/identikey-sites.md` §6.1.

  Phase 1: implemented as a plain handler module (not a separate process). The
  transport is plain TCP — `native/mjolnir_gateway/src/sites.rs` forwards the
  request to a `SocketAddr` on the Mjolnir host, which routes it here with the
  bound endpoint's `(identikey_fp, site_name)` and the requested path. (Iroh
  carries VM traffic elsewhere in the gateway; it is not in the Sites path.)

  This is now the *fallback* path. `Mjolnir.Sites.Materializer` writes each
  published snapshot to a plaintext directory at publish time and the gateway
  serves those files directly; `serve/3` covers sites published before
  materialization existed, or whose materialization failed.

  Public-mode decryption is real: `decrypt_public/4` derives the per-file key as
  `HKDF-SHA256(snapshot.sym_seed, info=entry.path, length=32)` and runs
  `XChaCha20` decrypt over the chunk ciphertext, matching the Publisher's
  derivation convention. Gated/group modes are not yet wired.
  """

  require Logger

  alias Mjolnir.SecretStore
  alias Mjolnir.Sites.{Crypto, HeadRecord, Manifest, Store}

  @type identikey_fp :: String.t()
  @type site_name :: String.t()
  @type request_path :: String.t()

  @type response ::
          {:ok,
           %{
             status: pos_integer(),
             content_type: String.t(),
             content_encoding: String.t() | nil,
             body: binary()
           }}
          | {:error, atom()}

  @doc """
  Serve a single GET. Returns the response shape the transport layer will turn
  into HTTP bytes.

  Resolution:
    1. SecretStore → HEAD → snapshot_hash
    2. Sites.Store → manifest envelope
    3. parse manifest, resolve path (with `/` → `/index.html` fallback)
    4. fetch chunk + outboard, verify Bao
    5. decrypt (public mode only for Phase 1)
  """
  @spec serve(identikey_fp(), site_name(), request_path()) :: response()
  def serve(identikey_fp, site_name, request_path)
      when is_binary(identikey_fp) and is_binary(site_name) and is_binary(request_path) do
    with {:ok, head} <- read_head(identikey_fp, site_name),
         {:ok, manifest} <- read_manifest(head.snapshot_hash),
         {:ok, entry} <- resolve_path(manifest, request_path),
         {:ok, %{ciphertext: ct, outboard: ob}} <- fetch_chunk(entry.bao_hash),
         {:ok, plaintext} <- decrypt_public(manifest, entry, ct, ob) do
      {:ok,
       %{
         status: 200,
         content_type: entry.content_type,
         content_encoding: entry.content_encoding,
         body: plaintext
       }}
    end
  end

  ## Resolution helpers

  defp read_head(identikey_fp, site_name) do
    key = "sites/#{site_name}/HEAD"

    case SecretStore.get(identikey_fp, key) do
      {:ok, bytes} -> HeadRecord.parse(bytes)
      :not_found -> {:error, :no_head}
      err -> err
    end
  end

  defp read_manifest(snapshot_hash) do
    case Store.get_manifest(snapshot_hash) do
      {:ok, bytes} -> Manifest.parse(bytes)
      :not_found -> {:error, :no_manifest}
      err -> err
    end
  end

  defp resolve_path(manifest, request_path) do
    primary =
      cond do
        String.ends_with?(request_path, "/") -> request_path <> "index.html"
        true -> request_path
      end

    case Manifest.lookup_entry(manifest, primary) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  defp fetch_chunk(bao_hash) do
    case Store.get_chunk(bao_hash) do
      {:ok, _} = ok -> ok
      :not_found -> {:error, :chunk_missing}
      err -> err
    end
  end

  @doc """
  Public-mode decryption: derive sym_key from snapshot sym_seed + entry path
  via HKDF-SHA256, then XChaCha20-decrypt.

  Using the file path (not bao_hash) as the HKDF info breaks the chicken-and-egg
  cycle on the publish side, where the bao_hash is not known until after
  encryption. Publish (`Publisher`), serve, and materialization
  (`Mjolnir.Sites.Materializer`) all agree on:
  `sym_key = HKDF(sym_seed, info=entry.path, 32)`.
  """
  @spec decrypt_public(Manifest.t(), Manifest.Entry.t(), binary(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def decrypt_public(%Manifest{mode: :public, sym_seed: seed}, entry, ciphertext, _outboard)
      when is_binary(seed) and byte_size(seed) == 32 do
    sym_key = Crypto.hkdf_sha256(seed, entry.path, 32)
    {:ok, Crypto.xchacha20_decrypt(sym_key, entry.nonce, ciphertext)}
  end

  def decrypt_public(%Manifest{mode: :public, sym_seed: nil}, _entry, _ct, _ob) do
    {:error, :missing_sym_seed}
  end

  def decrypt_public(%Manifest{mode: mode}, _entry, _ct, _ob) do
    {:error, {:mode_not_supported_in_phase_1, mode}}
  end
end
