defmodule Mjolnir.Sites.Storage.RecryptTest do
  @moduledoc """
  Round-trip test for the blob-door HTTP adapter.

  Tagged `:recrypt_storage` so it is **excluded from the default `mix test`**
  run (keeps macOS / CI-without-door green). It only runs where
  `mjolnir-blob-door` is reachable.

  ## How to run

  On the Mjolnir host, with the door bound on the overlay (see
  `docs/runbooks/blob-door.md`):

      MJOLNIR_RECRYPT_STORAGE_URL=http://10.200.0.1:7222 \\
        mix test test/mjolnir/sites/storage/recrypt_test.exs --include recrypt_storage
  """
  use ExUnit.Case, async: false

  alias Mjolnir.Sites.Storage.Recrypt
  alias Mjolnir.Sites.Store

  @moduletag :recrypt_storage

  setup do
    url = System.get_env("MJOLNIR_RECRYPT_STORAGE_URL")

    if is_nil(url) do
      # Belt-and-suspenders: even with --include recrypt_storage, skip when no
      # sidecar URL is configured so the test can never fail spuriously.
      {:ok, skip: true}
    else
      original_backend = Application.get_env(:mjolnir, :sites_storage_backend)
      original_url = Application.get_env(:mjolnir, :recrypt_storage_url)
      Application.put_env(:mjolnir, :sites_storage_backend, Recrypt)
      Application.put_env(:mjolnir, :recrypt_storage_url, url)

      on_exit(fn ->
        Application.put_env(:mjolnir, :sites_storage_backend, original_backend)
        Application.put_env(:mjolnir, :recrypt_storage_url, original_url)
      end)

      {:ok, skip: false}
    end
  end

  test "put_with_outboard chunk -> get_with_outboard -> hash matches", %{skip: skip} do
    if skip do
      # Documented contract, no reachable sidecar — nothing to assert.
      assert true
    else
      ciphertext = :crypto.strong_rand_bytes(64)
      # A small chunk (≤ 16 KiB) has no .obao; the round-trip must still return
      # the ciphertext and an empty outboard.
      outboard = <<>>
      hash = Mjolnir.Sites.Crypto.blake3_hash_base58(ciphertext)

      # put + get directly through the configured Store facade (the seam).
      assert :ok = Store.put_chunk(hash, ciphertext, outboard)
      assert {:ok, %{ciphertext: got_ct, outboard: got_ob}} = Store.get_chunk(hash)

      # Round-trip integrity: bytes survive and re-hash to the same address.
      assert got_ct == ciphertext
      assert got_ob == outboard
      assert Mjolnir.Sites.Crypto.blake3_hash_base58(got_ct) == hash
      assert Store.has_chunk?(hash)
    end
  end
end
