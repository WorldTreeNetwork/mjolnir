defmodule Mjolnir.Sites.Storage.Recrypt do
  @moduledoc """
  HTTP adapter that delegates chunk storage to the blob door
  (`mjolnir-blob-door`) on the Sites blob routes.

  ## Why a sidecar (and not a NIF)

  See the "Storage integration decision" note in
  `docs/plans/initiatives/identikey-sites.md`. In short:

    * `recrypt-storage` already implements content-addressed put/get **with Bao
      outboards** (`put_with_outboard` / `get_with_outboard` /
      `delete_with_outboard` on its `BlobStorage` trait) and an S3/B2 backend
      (`minio()`/path-style ctor). Reusing it avoids re-implementing the
      Bao-tree wiring in Elixir.
    * The `recrypt-ffi` crate exposes **crypto only** (OpenFHE/liboqs/ed25519),
      not storage. A NIF would mean either extending recrypt-ffi (pulling
      OpenFHE into the BEAM release build) or a fresh rustler crate against
      recrypt-storage — which still drags `aws-sdk-s3` + the recrypt git
      dependency into the BEAM build and **cannot build on macOS** (the whole
      recrypt workspace fails to compile on Darwin).
    * A sidecar keeps the BEAM build clean and crash-isolates storage —
      consistent with how Mjolnir already manages the hypervisor and the
      Forgejo runner. The sidecar is `mjolnir-blob-door`, not recrypt-server.

  ## Status: adapter ready; door install is `add-blob-door-overlay`

  The HTTP contract is the Sites blob routes (same as the door):

      PUT    /storage/blob/b3/{hash}            body = ciphertext
      PUT    /storage/blob/b3/{hash}.obao       body = outboard
      GET    /storage/blob/b3/{hash}            -> ciphertext
      GET    /storage/blob/b3/{hash}.obao       -> outboard (404 = none)

  `mjolnir-blob-door` implements these. recrypt-server `POST /files` is a
  multisig PRE surface and is **not** this adapter. The tagged
  `:recrypt_storage` test is skipped unless `MJOLNIR_RECRYPT_STORAGE_URL`
  points at a door. Operator path: `docs/runbooks/blob-door.md`.

  ## Configuration

      config :mjolnir, :sites_storage_backend, Mjolnir.Sites.Storage.Recrypt
      config :mjolnir, :recrypt_storage_url, "http://10.200.0.1:7222"

  or via env: `MJOLNIR_RECRYPT_STORAGE_URL=http://10.200.0.1:7222`.
  """

  @behaviour Mjolnir.Sites.Storage

  require Logger

  @default_timeout_ms 30_000

  @impl true
  def put_chunk(_bao_hash58, <<>>, _outboard), do: {:error, :empty_ciphertext}

  def put_chunk(bao_hash58, ciphertext, outboard)
      when is_binary(ciphertext) and is_binary(outboard) do
    with {:ok, base} <- base_url(),
         :ok <- put_object("#{base}/storage/blob/b3/#{bao_hash58}", ciphertext),
         :ok <- maybe_put_outboard(base, bao_hash58, outboard) do
      :ok
    end
  end

  @impl true
  def get_chunk(bao_hash58) do
    with {:ok, base} <- base_url() do
      case get_object("#{base}/storage/blob/b3/#{bao_hash58}") do
        {:ok, ciphertext} ->
          outboard =
            case get_object("#{base}/storage/blob/b3/#{bao_hash58}.obao") do
              {:ok, ob} -> ob
              :not_found -> <<>>
              {:error, _} -> <<>>
            end

          {:ok, %{ciphertext: ciphertext, outboard: outboard}}

        :not_found ->
          :not_found

        {:error, _} = err ->
          err
      end
    end
  end

  @impl true
  def has_chunk?(bao_hash58) do
    case get_chunk(bao_hash58) do
      {:ok, _} -> true
      _ -> false
    end
  end

  ## HTTP plumbing

  defp base_url do
    case Application.get_env(:mjolnir, :recrypt_storage_url) ||
           System.get_env("MJOLNIR_RECRYPT_STORAGE_URL") do
      nil -> {:error, :recrypt_storage_url_unset}
      url -> {:ok, String.trim_trailing(url, "/")}
    end
  end

  defp maybe_put_outboard(_base, _hash, <<>>), do: :ok

  defp maybe_put_outboard(base, bao_hash58, outboard) do
    put_object("#{base}/storage/blob/b3/#{bao_hash58}.obao", outboard)
  end

  defp put_object(url, body) do
    case Req.put(url,
           body: body,
           headers: [{"content-type", "application/octet-stream"}],
           receive_timeout: @default_timeout_ms,
           retry: false
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: resp}} ->
        {:error, {:http_status, status, resp}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp get_object(url) do
    case Req.get(url,
           headers: [{"accept", "application/octet-stream"}],
           receive_timeout: @default_timeout_ms,
           retry: false,
           decode_body: false
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, IO.iodata_to_binary(body)}

      {:ok, %Req.Response{status: 404}} ->
        :not_found

      {:ok, %Req.Response{status: status, body: resp}} ->
        {:error, {:http_status, status, resp}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end
end
