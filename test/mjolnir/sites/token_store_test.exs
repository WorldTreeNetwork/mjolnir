defmodule Mjolnir.Sites.TokenStoreTest do
  use ExUnit.Case, async: false

  alias Mjolnir.Sites.{Token, TokenStore}

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("mjolnir-token-store-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    original = Application.get_env(:mjolnir, :sites_token_dir)
    Application.put_env(:mjolnir, :sites_token_dir, tmp)

    # Each test uses its own fingerprint so the process-wide ETS cache (owned by
    # the supervised TokenStore) cannot leak assertions between tests.
    fp = "fp#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Enum.each(TokenStore.list(), fn t ->
        if t.identikey_fp == fp, do: TokenStore.delete(t.id)
      end)

      Application.put_env(:mjolnir, :sites_token_dir, original)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, fp: fp}
  end

  describe "create/2 and verify/1" do
    test "a freshly minted token verifies", %{fp: fp} do
      assert {:ok, token, plaintext} = TokenStore.create(fp)
      assert {:ok, verified} = TokenStore.verify(plaintext)
      assert verified.id == token.id
      assert verified.identikey_fp == fp
    end

    test "carries its bindings through", %{fp: fp} do
      {:ok, _token, plaintext} = TokenStore.create(fp, site_name: "blog", description: "ci")
      assert {:ok, verified} = TokenStore.verify(plaintext)
      assert verified.site_name == "blog"
      assert verified.description == "ci"
    end

    test "rejects an unknown id", %{fp: fp} do
      {:ok, _token, _plaintext} = TokenStore.create(fp)
      assert {:error, :unknown} = TokenStore.verify("mjsk_deadbeefdeadbeef_somesecret")
    end

    test "rejects a valid id with the wrong secret", %{fp: fp} do
      {:ok, token, _plaintext} = TokenStore.create(fp)
      assert {:error, :bad_secret} = TokenStore.verify("mjsk_#{token.id}_wrongsecret")
    end

    test "rejects malformed credentials" do
      assert {:error, :malformed} = TokenStore.verify("garbage")
      assert {:error, :malformed} = TokenStore.verify("mjsk_onlyid")
      assert {:error, :malformed} = TokenStore.verify(nil)
    end

    test "one token's secret does not verify another token", %{fp: fp} do
      {:ok, a, _} = TokenStore.create(fp)
      {:ok, _b, b_plain} = TokenStore.create(fp)
      {:ok, {_id, b_secret}} = Token.parse(b_plain)

      assert {:error, :bad_secret} = TokenStore.verify("mjsk_#{a.id}_#{b_secret}")
    end
  end

  describe "storage hygiene" do
    test "only a hash reaches disk — never the plaintext", %{tmp: tmp, fp: fp} do
      {:ok, token, plaintext} = TokenStore.create(fp)
      {:ok, {_id, secret}} = Token.parse(plaintext)

      path = Path.join(tmp, "#{token.id}.json")
      assert File.exists?(path)
      on_disk = File.read!(path)

      refute on_disk =~ secret
      refute on_disk =~ plaintext
      assert on_disk =~ token.secret_hash

      # And the stored hash really is the hash of the issued secret.
      assert Jason.decode!(on_disk)["secret_hash"] == Token.hash_secret(secret)
    end

    test "the record file is not world-readable", %{tmp: tmp, fp: fp} do
      {:ok, token, _plaintext} = TokenStore.create(fp)
      %{mode: mode} = File.stat!(Path.join(tmp, "#{token.id}.json"))

      # Owner read/write only.
      assert Bitwise.band(mode, 0o077) == 0
    end

    test "survives a restart by reloading from disk", %{fp: fp} do
      {:ok, token, plaintext} = TokenStore.create(fp)

      # Drop the cache entry, then reload the way init/1 does.
      TokenStore.delete(token.id)
      assert {:error, :unknown} = TokenStore.verify(plaintext)

      :ok = TokenStore.put(token)
      assert {:ok, reloaded} = TokenStore.verify(plaintext)
      assert reloaded.id == token.id
    end

    test "refuses a traversing token id without killing the store", %{fp: fp} do
      {:ok, token, plaintext} = TokenStore.create(fp)

      assert {:error, :invalid_token_id} = TokenStore.put(%{token | id: "../../etc/passwd"})
      assert {:error, :invalid_token_id} = TokenStore.delete("../../etc/passwd")

      # The store is still alive and its cache intact.
      assert {:ok, _} = TokenStore.verify(plaintext)
    end
  end

  describe "revocation" do
    test "a revoked token stops verifying", %{fp: fp} do
      {:ok, token, plaintext} = TokenStore.create(fp)
      assert {:ok, _} = TokenStore.verify(plaintext)

      assert :ok = TokenStore.revoke(token.id)
      assert {:error, :revoked} = TokenStore.verify(plaintext)
    end

    test "revocation persists to disk", %{tmp: tmp, fp: fp} do
      {:ok, token, _plaintext} = TokenStore.create(fp)
      :ok = TokenStore.revoke(token.id)

      record = Jason.decode!(File.read!(Path.join(tmp, "#{token.id}.json")))
      refute is_nil(record["revoked_at"])
    end

    test "is idempotent and does not rewrite the audit timestamp", %{fp: fp} do
      {:ok, token, _} = TokenStore.create(fp)
      :ok = TokenStore.revoke(token.id)
      {:ok, first} = TokenStore.get(token.id)

      :ok = TokenStore.revoke(token.id)
      {:ok, second} = TokenStore.get(token.id)

      assert first.revoked_at == second.revoked_at
    end

    test "revoking an unknown id reports not_found" do
      assert :not_found = TokenStore.revoke("aaaaaaaaaaaaaaaa")
    end
  end

  describe "expiry" do
    test "an expired token stops verifying", %{fp: fp} do
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      {:ok, _token, plaintext} = TokenStore.create(fp, expires_at: past)

      assert {:error, :expired} = TokenStore.verify(plaintext)
    end

    test "a future expiry still verifies", %{fp: fp} do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      {:ok, _token, plaintext} = TokenStore.create(fp, expires_at: future)

      assert {:ok, _} = TokenStore.verify(plaintext)
    end

    test "a wrong secret on an expired token still reports bad_secret", %{fp: fp} do
      # The secret is always checked first, so expiry cannot be used to probe
      # whether an id exists with a guessable secret.
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      {:ok, token, _plaintext} = TokenStore.create(fp, expires_at: past)

      assert {:error, :bad_secret} = TokenStore.verify("mjsk_#{token.id}_nope")
    end
  end

  describe "list/0" do
    test "returns created tokens for this fingerprint", %{fp: fp} do
      {:ok, a, _} = TokenStore.create(fp, description: "one")
      {:ok, b, _} = TokenStore.create(fp, description: "two")

      ids = TokenStore.list() |> Enum.filter(&(&1.identikey_fp == fp)) |> Enum.map(& &1.id)

      assert a.id in ids
      assert b.id in ids
    end
  end
end
