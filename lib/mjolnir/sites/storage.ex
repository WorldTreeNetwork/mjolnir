defmodule Mjolnir.Sites.Storage do
  @moduledoc """
  Behaviour for the content-addressed chunk backend behind `Mjolnir.Sites.Store`.

  This is the **storage seam** (see `docs/plans/initiatives/identikey-sites.md`
  §4, §6.1, and the "Storage integration decision" note). Callers always go
  through `Mjolnir.Sites.Store`; the concrete backend is chosen at runtime via
  the `:sites_storage_backend` application env:

      config :mjolnir, :sites_storage_backend, Mjolnir.Sites.Storage.Local

  Implementations:

    * `Mjolnir.Sites.Storage.Local` — the default. Writes ciphertext + outboard
      siblings as BTRFS files using the same on-disk layout as recrypt's
      `LocalFileStorage` (`blob/b3/<hash58>` + `.obao`). This is the fallback
      that keeps the unit suite green on machines without the recrypt sidecar.

    * `Mjolnir.Sites.Storage.Recrypt` — HTTP adapter that delegates to the
      `recrypt-storage` crate via the `recrypt-server` sidecar. This is the
      chosen production direction (see the design-doc decision note). It is
      scaffolded but gated: it only runs where the sidecar is reachable
      (currently the Mjolnir server, never macOS — recrypt's Rust build pulls
      OpenFHE/liboqs, which do not build on Darwin).

  Only the chunk (ciphertext + outboard) operations are part of this seam.
  Manifest and OTS storage remain local-only on the host filesystem (they are
  small signed records / receipts, not part of the recrypt blob store) and stay
  on `Mjolnir.Sites.Store` directly.
  """

  @typedoc "Blake3 root hash of the ciphertext, base58-encoded."
  @type bao_hash58 :: String.t()

  @doc """
  Persist a ciphertext chunk and its Bao outboard sibling, verifying the bytes
  hash to `bao_hash58`. Must be atomic: on `{:error, _}` nothing is left behind.

  An empty `outboard` is permitted (small-file case, ciphertext ≤ 16 KiB) and
  means "no `.obao` sibling".
  """
  @callback put_chunk(bao_hash58, ciphertext :: binary(), outboard :: binary()) ::
              :ok | {:error, term()}

  @doc """
  Fetch a chunk's ciphertext + outboard. Returns `:not_found` when the
  ciphertext object is absent. Outboard is `<<>>` when no `.obao` sibling exists.
  """
  @callback get_chunk(bao_hash58) ::
              {:ok, %{ciphertext: binary(), outboard: binary()}} | :not_found | {:error, term()}

  @doc "True if a chunk's ciphertext is present in the backend."
  @callback has_chunk?(bao_hash58) :: boolean()

  @doc """
  Resolve the configured backend module. Defaults to
  `Mjolnir.Sites.Storage.Local` so unit tests and recrypt-less hosts stay green.
  """
  @spec backend() :: module()
  def backend do
    Application.get_env(:mjolnir, :sites_storage_backend, Mjolnir.Sites.Storage.Local)
  end
end
