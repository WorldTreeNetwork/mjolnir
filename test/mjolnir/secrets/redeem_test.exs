defmodule Mjolnir.Secrets.RedeemTest do
  use ExUnit.Case, async: false

  alias Mjolnir.Secrets.{Nonces, Redeem}

  alias Mjolnir.{Biscuit, SecretStore}

  setup do
    root = Path.join(System.tmp_dir!(), "redeem-#{System.unique_integer([:positive])}")
    keys = [:secret_store_root, :biscuit_public_hex, :egress_allow_hosts]
    original = Map.new(keys, &{&1, Application.fetch_env(:mjolnir, &1)})
    issuer = Biscuit.keypair()
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    fp = Base.encode16(Biscuit.holder_fingerprint(public), case: :lower)
    Application.put_env(:mjolnir, :secret_store_root, root)
    Application.put_env(:mjolnir, :biscuit_public_hex, issuer.public_hex)
    Application.put_env(:mjolnir, :egress_allow_hosts, ["127.0.0.1"])

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:mjolnir, key, value)
        {key, :error} -> Application.delete_env(:mjolnir, key)
      end)

      File.rm_rf!(root)
    end)

    id = "test-secret"
    value = <<0, 255>> <> "private-value"
    salt = :crypto.strong_rand_bytes(32)

    meta = %{
      "salt_b64" => Base.encode64(salt),
      "commitment_hex" => Base.encode16(Biscuit.secret_commit(salt, value), case: :lower),
      "ignored" => %{"future" => true}
    }

    :ok = SecretStore.put_opaque("secrets", id, "value", value)
    :ok = SecretStore.put_opaque("secrets", id, "meta", Jason.encode!(meta))
    token = held_token(issuer, id, "redeem", fp)

    %{
      id: id,
      value: value,
      salt: salt,
      meta: meta,
      issuer: issuer,
      public: public,
      private: private,
      fp: fp,
      token: token
    }
  end

  defp held_token(issuer, resource, operation, fp) do
    issuer.private_hex
    |> Biscuit.mint(resource, operation)
    |> Biscuit.append_holder(issuer.public_hex, fp)
    |> Base.encode64()
  end

  defp proof(ctx, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          "secret_id" => ctx.id,
          "nonce" => Nonces.issue(),
          "biscuit" => ctx.token,
          "public_key" => Base.encode64(ctx.public)
        },
        overrides
      )

    message = Redeem.signing_message(params["nonce"], params["biscuit"], params["secret_id"])
    signature = :crypto.sign(:eddsa, :none, message, [ctx.private, :ed25519])
    Map.put(params, "signature", Base.encode64(signature))
  end

  test "copy-out returns the stored binary value and salt and rejects replay", ctx do
    params = proof(ctx)
    assert {:ok, ctx.value, ctx.salt} == Redeem.redeem(params)
    assert {:error, :invalid_proof} = Redeem.redeem(params)
  end

  test "missing, legacy and malformed records all fail without logging the pair", ctx do
    bad_meta = [
      "{",
      <<255>>,
      "null",
      "[]",
      "{}",
      Jason.encode!(Map.put(ctx.meta, "salt_b64", nil)),
      Jason.encode!(Map.put(ctx.meta, "salt_b64", "!")),
      Jason.encode!(Map.put(ctx.meta, "salt_b64", Base.encode64(<<0::248>>))),
      Jason.encode!(Map.put(ctx.meta, "salt_b64", Base.encode64(<<0::264>>))),
      Jason.encode!(Map.put(ctx.meta, "commitment_hex", nil)),
      Jason.encode!(Map.put(ctx.meta, "commitment_hex", String.duplicate("a", 62))),
      Jason.encode!(Map.put(ctx.meta, "commitment_hex", String.duplicate("a", 66))),
      Jason.encode!(Map.put(ctx.meta, "commitment_hex", String.duplicate("A", 64))),
      Jason.encode!(Map.put(ctx.meta, "commitment_hex", String.duplicate("g", 64))),
      Jason.encode!(Map.put(ctx.meta, "commitment_hex", String.duplicate("0", 64))),
      Jason.encode!(Map.put(ctx.meta, "salt_b64", Base.encode64(:crypto.strong_rand_bytes(32))))
    ]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Enum.each(bad_meta, fn meta ->
          :ok = SecretStore.put_opaque("secrets", ctx.id, "meta", meta)
          assert {:error, :not_found} = Redeem.redeem(proof(ctx))
          assert {:error, :not_found} = Redeem.egress(proof(ctx))
        end)

        :ok = SecretStore.delete_opaque("secrets", ctx.id, "meta")
        assert {:error, :not_found} = Redeem.redeem(proof(ctx))
        assert {:error, :not_found} = Redeem.egress(proof(ctx))
        :ok = SecretStore.put_opaque("secrets", ctx.id, "meta", Jason.encode!(ctx.meta))
        :ok = SecretStore.delete_opaque("secrets", ctx.id, "value")
        assert {:error, :not_found} = Redeem.redeem(proof(ctx))
        assert {:error, :not_found} = Redeem.egress(proof(ctx))
      end)

    refute log =~ ctx.value
    refute log =~ ctx.salt
    refute log =~ Base.encode64(ctx.value)
    refute log =~ Base.encode64(ctx.salt)
  end

  test "failed signatures and Biscuit checks burn the nonce", ctx do
    {_, wrong_private} = :crypto.generate_key(:eddsa, :ed25519)
    wrong_signer = proof(%{ctx | private: wrong_private})
    holderless = ctx.issuer.private_hex |> Biscuit.mint(ctx.id, "redeem") |> Base.encode64()

    invalid = [
      wrong_signer,
      proof(ctx, %{"biscuit" => holderless}),
      proof(ctx, %{"biscuit" => held_token(ctx.issuer, "other", "redeem", ctx.fp)}),
      proof(ctx, %{"biscuit" => held_token(ctx.issuer, ctx.id, "write", ctx.fp)}),
      Map.put(proof(ctx), "secret_id", "tampered"),
      Map.put(proof(ctx), "secret_id", ""),
      Map.put(proof(ctx), "biscuit", ctx.token <> "tampered"),
      Map.put(proof(ctx), "signature", "!")
    ]

    Enum.each(invalid, fn params ->
      assert {:error, _} = Redeem.redeem(params)
      assert {:error, :invalid_proof} = Redeem.redeem(proof(ctx, %{"nonce" => params["nonce"]}))
    end)
  end

  test "expired and unknown nonces fail, and concurrent replay has one winner", ctx do
    expired = Nonces.issue()
    :sys.replace_state(Nonces, &Map.put(&1, expired, System.monotonic_time(:second) - 1))
    assert {:error, :invalid_proof} = Redeem.redeem(proof(ctx, %{"nonce" => expired}))
    assert {:error, :invalid_proof} = Redeem.redeem(proof(ctx, %{"nonce" => "unknown"}))
    params = proof(ctx)

    results =
      1..2
      |> Task.async_stream(fn _ -> Redeem.redeem(params) end)
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &match?({:ok, _, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid_proof})) == 1
  end

  test "egress sends the value upstream but never returns the pair", ctx do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)

    upstream =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 201 Created\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
          )

        :gen_tcp.close(socket)
        request
      end)

    # Use a valid HTTP header value for this fixture.
    value = "upstream-token"

    meta =
      Map.put(
        ctx.meta,
        "commitment_hex",
        Base.encode16(Biscuit.secret_commit(ctx.salt, value), case: :lower)
      )

    :ok = SecretStore.put_opaque("secrets", ctx.id, "value", value)
    :ok = SecretStore.put_opaque("secrets", ctx.id, "meta", Jason.encode!(meta))
    request = %{"method" => "GET", "url" => "http://127.0.0.1:#{port}/"}
    assert {:ok, 201, "ok"} = Redeem.egress(Map.merge(proof(ctx), request))
    assert Task.await(upstream) =~ "Bearer " <> value

    :ok = SecretStore.delete_opaque("secrets", ctx.id, "meta")
    assert {:error, :not_found} = Redeem.egress(Map.merge(proof(ctx), request))
    assert {:error, :timeout} = :gen_tcp.accept(listener, 50)
  end

  test "a nonce is single use" do
    nonce = Nonces.issue()
    assert :ok = Nonces.consume(nonce)
    assert :error = Nonces.consume(nonce)
  end

  test "egress does not return a secret when the proof is missing" do
    assert {:error, :invalid_proof} =
             Redeem.egress(%{"url" => "https://example.com", "method" => "GET"})
  end

  test "the signing message binds nonce, token, and secret id" do
    assert Redeem.signing_message("abc", "dG9r", "github-pat") ==
             "mjolnir/redeem/v1\nabc\ndG9r\ngithub-pat"
  end
end
