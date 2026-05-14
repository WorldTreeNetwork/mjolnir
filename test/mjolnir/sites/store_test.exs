defmodule Mjolnir.Sites.StoreTest do
  use ExUnit.Case, async: false

  alias Mjolnir.Sites.Store

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("mjolnir-sites-store-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([tmp, "blob", "b3"]))
    File.mkdir_p!(Path.join([tmp, "manifests"]))

    original = Application.get_env(:mjolnir, :sites_root)
    Application.put_env(:mjolnir, :sites_root, tmp)

    on_exit(fn ->
      Application.put_env(:mjolnir, :sites_root, original)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  @manifest_hash "manifestHash999"

  defp hash_of(bytes), do: Mjolnir.Sites.Crypto.blake3_hash_base58(bytes)

  test "put_chunk + get_chunk round-trip with verified hash" do
    ct = "ciphertext-bytes"
    ob = "outboard-bytes"
    hash = hash_of(ct)
    assert :ok = Store.put_chunk(hash, ct, ob)
    assert {:ok, %{ciphertext: ^ct, outboard: ^ob}} = Store.get_chunk(hash)
    assert Store.has_chunk?(hash)
  end

  test "put_chunk rejects mismatched hash" do
    ct = "ciphertext-bytes"
    assert {:error, {:bao_mismatch, _}} = Store.put_chunk("wrongHash123", ct, "ob")
  end

  test "get_chunk returns :not_found when absent" do
    assert :not_found = Store.get_chunk("zzz999missing")
    refute Store.has_chunk?("zzz999missing")
  end

  test "put_manifest + get_manifest" do
    bytes = "manifest-envelope"
    assert :ok = Store.put_manifest(@manifest_hash, bytes)
    assert {:ok, ^bytes} = Store.get_manifest(@manifest_hash)
  end

  test "put_ots + get_ots" do
    bytes = "ots-receipt"
    assert :ok = Store.put_ots(@manifest_hash, bytes)
    assert {:ok, ^bytes} = Store.get_ots(@manifest_hash)
  end

  test "rejects empty ciphertext" do
    assert {:error, :empty_ciphertext} = Store.put_chunk("anyhash", "", "ob")
  end

  test "rejects invalid hash characters" do
    assert_raise ArgumentError, fn -> Store.chunk_path("has/slash") end
    assert_raise ArgumentError, fn -> Store.chunk_path("has space") end
  end
end
