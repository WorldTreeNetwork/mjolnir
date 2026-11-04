defmodule Mjolnir.Secrets.DepositTest do
  use ExUnit.Case, async: false

  alias Mjolnir.{Biscuit, SecretStore}
  alias Mjolnir.Secrets.{Deposit, Nonces, Redeem}

  setup do
    root = Path.join(System.tmp_dir!(), "deposit-#{System.unique_integer([:positive])}")
    keys = [:secret_store_root, :deposit_test_hook, :biscuit_public_hex]
    original = Map.new(keys, &{&1, Application.fetch_env(:mjolnir, &1)})
    Application.put_env(:mjolnir, :secret_store_root, root)
    Application.delete_env(:mjolnir, :deposit_test_hook)
    Application.delete_env(:mjolnir, :biscuit_public_hex)
    issuer = Biscuit.authority()
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:mjolnir, key, value)
        {key, :error} -> Application.delete_env(:mjolnir, key)
      end)

      File.rm_rf!(root)
    end)

    %{
      root: root,
      id: "foreign-secret",
      value: "private-deposit-value-" <> Base.encode64(:crypto.strong_rand_bytes(32)),
      public: public,
      private: private,
      issuer: issuer
    }
  end

  test "publishes exactly three opaque objects and a holder-checked production token", ctx do
    {:ok, token} = Deposit.deposit(ctx.id, ctx.value, ctx.public)
    assert Enum.sort(File.ls!(directory(ctx))) == ["meta", "owner", "value"]
    assert {:ok, ctx.value} == SecretStore.get_opaque("secrets", ctx.id, "value")
    {:ok, json} = SecretStore.get_opaque("secrets", ctx.id, "meta")
    assert String.valid?(json)
    meta = Jason.decode!(json)
    assert Enum.sort(Map.keys(meta)) == ["commitment_hex", "salt_b64"]
    salt = Base.decode64!(meta["salt_b64"])
    assert byte_size(salt) == 32
    assert meta["commitment_hex"] =~ ~r/\A[0-9a-f]{64}\z/

    assert Base.decode16!(meta["commitment_hex"], case: :lower) ==
             Biscuit.secret_commit(salt, ctx.value)

    fp = Base.encode16(Biscuit.holder_fingerprint(ctx.public), case: :lower)
    assert {:ok, fp} == SecretStore.get_opaque("secrets", ctx.id, "owner")
    assert fp =~ ~r/\A[0-9a-f]{64}\z/
    assert :ok = Biscuit.parse(token, ctx.issuer.public_hex)
    assert :ok = Biscuit.authorize(token, ctx.issuer.public_hex, fp, ctx.id, "redeem", true)

    assert {:error, _} =
             Biscuit.authorize(token, ctx.issuer.public_hex, fp, ctx.id, "redeem", false)

    assert {:error, _} =
             Biscuit.authorize(
               token,
               ctx.issuer.public_hex,
               String.duplicate("0", 64),
               ctx.id,
               "redeem",
               true
             )

    assert {:error, _} =
             Biscuit.authorize(token, ctx.issuer.public_hex, fp, ctx.id, "write", true)

    # The serialized token contains symbols as text. Neither private input is
    # present, in raw bytes or encoded form.
    for bytes <- [ctx.value, salt, Base.encode64(ctx.value), Base.encode64(salt)] do
      assert :binary.match(token, bytes) == :nomatch
    end

    params = %{
      "secret_id" => ctx.id,
      "audience" => "test",
      "method" => "REDEEM",
      "resource" => ctx.id,
      "nonce" => Nonces.issue(),
      "biscuit" => Base.encode64(token),
      "public_key" => Base.encode64(ctx.public)
    }

    signature =
      :crypto.sign(
        :eddsa,
        :none,
        Redeem.signing_message(params["nonce"], params["biscuit"], params),
        [ctx.private, :ed25519]
      )

    assert {:ok, ctx.value, salt} ==
             Redeem.redeem(Map.put(params, "signature", Base.encode64(signature)))
  end

  test "fresh deposits draw distinct salts", ctx do
    for id <- [ctx.id, "another-secret"] do
      assert {:ok, _} = Deposit.deposit(id, ctx.value, ctx.public)
    end

    {:ok, first} = SecretStore.get_opaque("secrets", ctx.id, "meta")
    {:ok, second} = SecretStore.get_opaque("secrets", "another-secret", "meta")
    refute Jason.decode!(first)["salt_b64"] == Jason.decode!(second)["salt_b64"]
  end

  test "invalid inputs create nothing", ctx do
    for id <- ["", ".", "..", "a..b", "a/b", "a\\b", "a\0b", <<255>>, nil, 123] do
      assert {:error, :invalid_deposit} = Deposit.deposit(id, ctx.value, ctx.public)
      refute File.exists?(ctx.root)
    end

    for value <- ["", nil, 123],
        do: assert({:error, :invalid_deposit} == Deposit.deposit(ctx.id, value, ctx.public))

    for owner <- ["", <<0::248>>, <<0::264>>, nil, 123],
        do: assert({:error, :invalid_deposit} == Deposit.deposit(ctx.id, ctx.value, owner))

    refute File.exists?(ctx.root)
  end

  test "duplicate id preserves the original record and token", ctx do
    {:ok, token} = Deposit.deposit(ctx.id, ctx.value, ctx.public)
    before = snapshot(ctx)
    assert {:error, :already_exists} = Deposit.deposit(ctx.id, "replacement", ctx.public)
    assert snapshot(ctx) == before
    assert :ok = Biscuit.parse(token, ctx.issuer.public_hex)
  end

  test "partial directory and every existing tmp sibling are untouched", ctx do
    File.mkdir_p!(directory(ctx))

    for key <- ["value", "meta.tmp", "owner.tmp", "value.tmp"] do
      File.write!(Path.join(directory(ctx), key), "existing-#{key}")
    end

    before = snapshot(ctx)

    Application.put_env(:mjolnir, :deposit_test_hook, fn _ ->
      flunk("loser entered publication")
    end)

    assert {:error, :already_exists} = Deposit.deposit(ctx.id, ctx.value, ctx.public)
    assert snapshot(ctx) == before
  end

  test "a losing concurrent deposit cannot publish or delete the winner", ctx do
    parent = self()

    Application.put_env(:mjolnir, :deposit_test_hook, fn
      :reserved ->
        send(parent, {:reserved, self()})

        receive do
          :publish -> :ok
        after
          5_000 -> raise "reservation barrier timed out"
        end

      _ ->
        :ok
    end)

    winner = Task.async(fn -> Deposit.deposit(ctx.id, ctx.value, ctx.public) end)
    assert_receive {:reserved, pid}
    loser = Task.async(fn -> Deposit.deposit(ctx.id, "losing-secret", ctx.public) end)
    assert {:error, :already_exists} = Task.await(loser)
    assert File.dir?(directory(ctx))
    assert File.ls!(directory(ctx)) == []
    send(pid, :publish)
    assert {:ok, _} = Task.await(winner)
    assert {:ok, ctx.value} == SecretStore.get_opaque("secrets", ctx.id, "value")
    assert Enum.sort(File.ls!(directory(ctx))) == ["meta", "owner", "value"]
  end

  test "a later real write failure removes all owned files and tmp siblings", ctx do
    Application.put_env(:mjolnir, :deposit_test_hook, fn
      {:write, "meta"} ->
        assert File.read!(Path.join(directory(ctx), "value")) == ctx.value
        File.mkdir_p!(Path.join(directory(ctx), "meta.tmp"))
        File.write!(Path.join(directory(ctx), "value.tmp"), ctx.value)
        File.write!(Path.join(directory(ctx), "owner.tmp"), "partial")
        :ok

      _ ->
        :ok
    end)

    assert {:error, :publication_failed} = Deposit.deposit(ctx.id, ctx.value, ctx.public)
    refute File.exists?(directory(ctx))
  end

  for stage <- [:mint, :append] do
    test "#{stage} failure returns no token and removes the published trio", ctx do
      stage = unquote(stage)

      Application.put_env(:mjolnir, :deposit_test_hook, fn
        ^stage ->
          assert Enum.sort(File.ls!(directory(ctx))) == ["meta", "owner", "value"]
          raise ctx.value

        _ ->
          :ok
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :publication_failed} = Deposit.deposit(ctx.id, ctx.value, ctx.public)
        end)

      refute log =~ ctx.value
      refute File.exists?(directory(ctx))
    end
  end

  test "a production mint error also rolls back", ctx do
    Application.put_env(:mjolnir, :biscuit_public_hex, String.duplicate("0", 64))
    assert {:error, :publication_failed} = Deposit.deposit(ctx.id, ctx.value, ctx.public)
    refute File.exists?(directory(ctx))
  end

  test "cleanup failure leaves a refused reservation without exposing secret bytes", ctx do
    Application.put_env(:mjolnir, :deposit_test_hook, fn
      :append -> raise ctx.value
      :cleanup -> raise ctx.value
      _ -> :ok
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :cleanup_failed} = result = Deposit.deposit(ctx.id, ctx.value, ctx.public)
        refute inspect(result) =~ ctx.value
      end)

    refute log =~ ctx.value
    assert File.dir?(directory(ctx))
    before = snapshot(ctx)
    Application.delete_env(:mjolnir, :deposit_test_hook)
    assert {:error, :already_exists} = Deposit.deposit(ctx.id, "replacement", ctx.public)
    assert snapshot(ctx) == before
  end

  defp directory(ctx), do: Path.join([ctx.root, "_opaque", "secrets", ctx.id])

  defp snapshot(ctx) do
    Map.new(File.ls!(directory(ctx)), fn name ->
      {name, File.read!(Path.join(directory(ctx), name))}
    end)
  end
end
