defmodule Mjolnir.Sites.Storage.Local do
  @moduledoc """
  Default chunk backend: BTRFS-backed local files.

  On-disk layout matches recrypt's `LocalFileStorage`
  (`crates/recrypt-storage/src/local.rs`):

      <sites_root>/blob/b3/<bao_hash58>          ciphertext chunk
      <sites_root>/blob/b3/<bao_hash58>.obao     Bao outboard sibling (optional)

  Writes verify the supplied `bao_hash58` matches a whole-content Blake3 hash of
  the ciphertext before anything lands on disk. (Phase 1 verifies the root hash;
  incremental `.obao` stream-verification arrives with the real Bao-tree wiring —
  ultimately delegated to `recrypt-storage` via the sidecar backend.)
  """

  @behaviour Mjolnir.Sites.Storage

  alias Mjolnir.Sites.Store

  @impl true
  def put_chunk(_bao_hash58, <<>>, _outboard), do: {:error, :empty_ciphertext}

  def put_chunk(bao_hash58, ciphertext, outboard)
      when is_binary(ciphertext) and is_binary(outboard) do
    with :ok <- verify_bao(bao_hash58, ciphertext),
         :ok <- write_atomic(Store.chunk_path(bao_hash58), ciphertext),
         :ok <- maybe_write_outboard(bao_hash58, outboard) do
      :ok
    end
  end

  @impl true
  def get_chunk(bao_hash58) do
    cp = Store.chunk_path(bao_hash58)
    op = Store.outboard_path(bao_hash58)

    case File.read(cp) do
      {:ok, ct} ->
        outboard =
          case File.read(op) do
            {:ok, ob} -> ob
            {:error, :enoent} -> <<>>
            {:error, _} = err -> throw(err)
          end

        {:ok, %{ciphertext: ct, outboard: outboard}}

      {:error, :enoent} ->
        :not_found

      {:error, _} = err ->
        err
    end
  catch
    {:error, _} = err -> err
  end

  @impl true
  def has_chunk?(bao_hash58) do
    File.regular?(Store.chunk_path(bao_hash58))
  end

  ## Internals

  # Whole-content Blake3 verification. Phase 1 does not stream-verify with the
  # `.obao`; that arrives with the real Bao-tree wiring (sidecar backend). The
  # outboard bytes are stored as-supplied (empty allowed) for future use.
  defp verify_bao(bao_hash58, ciphertext) do
    actual = Mjolnir.Sites.Crypto.blake3_hash_base58(ciphertext)

    if actual == bao_hash58 do
      :ok
    else
      {:error, {:bao_mismatch, expected: bao_hash58, actual: actual}}
    end
  end

  defp maybe_write_outboard(_bao_hash58, <<>>), do: :ok

  defp maybe_write_outboard(bao_hash58, outboard) do
    write_atomic(Store.outboard_path(bao_hash58), outboard)
  end

  defp write_atomic(final, bytes) do
    tmp = final <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(final)),
         {:ok, io} <- :file.open(tmp, [:raw, :write, :binary]),
         :ok <- :file.write(io, bytes),
         :ok <- :file.sync(io),
         :ok <- :file.close(io),
         :ok <- File.rename(tmp, final) do
      :ok
    else
      error ->
        _ = File.rm(tmp)
        {:error, error}
    end
  end
end
