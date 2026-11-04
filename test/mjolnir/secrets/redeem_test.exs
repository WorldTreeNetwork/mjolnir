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
          "audience" => "test",
          "method" => "REDEEM",
          "resource" => ctx.id,
          "nonce" => Nonces.issue(),
          "biscuit" => ctx.token,
          "public_key" => Base.encode64(ctx.public)
        },
        overrides
      )

    message = Redeem.signing_message(params["nonce"], params["biscuit"], params)
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

  defp listener do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    {listener, "http://127.0.0.1:#{port}/signed?x=1"}
  end

  defp receive_request(socket, data \\ "") do
    case :binary.split(data, "\r\n\r\n") do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)

        if byte_size(body) >= String.to_integer(length) do
          data
        else
          {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
          receive_request(socket, data <> more)
        end

      _ ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
        receive_request(socket, data <> more)
    end
  end

  test "egress forwards the signed method, URL, binary body and exact idempotency key", ctx do
    {listener, url} = listener()
    value = "upstream-token"

    meta =
      Map.put(
        ctx.meta,
        "commitment_hex",
        Base.encode16(Biscuit.secret_commit(ctx.salt, value), case: :lower)
      )

    :ok = SecretStore.put_opaque("secrets", ctx.id, "value", value)
    :ok = SecretStore.put_opaque("secrets", ctx.id, "meta", Jason.encode!(meta))
    body = <<0, 255>> <> "hi"

    # Repeating a key still calls upstream; missing and empty keys add no header.
    for key <- ["Same KEY / Exact", "Same KEY / Exact", "", nil] do
      upstream =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 5_000)
          request = receive_request(socket)

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 201 Created\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
            )

          :gen_tcp.close(socket)
          request
        end)

      fields = %{
        "method" => "PATCH",
        "resource" => url,
        "body_b64" => Base.encode64(body),
        "audience" => "opaque label unrelated to host"
      }

      fields = if is_nil(key), do: fields, else: Map.put(fields, "idempotency_key", key)

      params =
        proof(ctx, fields)
        |> Map.merge(%{
          "url" => "https://ignored.invalid",
          "http_method" => "DELETE",
          "body_digest" => "ignored client digest"
        })

      assert {:ok, 201, "ok"} = Redeem.egress(params)
      request = Task.await(upstream)
      [headers, actual_body] = :binary.split(request, "\r\n\r\n")
      assert headers =~ "PATCH /signed?x=1 HTTP/1.1"
      assert String.downcase(headers) =~ "host: 127.0.0.1:"
      assert headers =~ "Bearer " <> value
      assert actual_body == body

      if key in [nil, ""] do
        refute String.downcase(headers) =~ "idempotency-key:"
      else
        assert Enum.any?(String.split(headers, "\r\n"), fn line ->
                 case String.split(line, ": ", parts: 2) do
                   [name, value] -> String.downcase(name) == "idempotency-key" and value == key
                   _ -> false
                 end
               end)
      end
    end
  end

  test "failed egress proofs burn nonces and make no upstream call", ctx do
    {listener, url} = listener()

    base = %{
      "method" => "POST",
      "resource" => url,
      "body_b64" => Base.encode64("hi"),
      "idempotency_key" => "k1"
    }

    tampered = %{
      "biscuit" => ctx.token <> "A",
      "nonce" => Nonces.issue(),
      "audience" => "other",
      "method" => "PUT",
      "resource" => url <> "other",
      "body_b64" => Base.encode64("bye"),
      "secret_id" => "other",
      "idempotency_key" => "k2"
    }

    invalid = Enum.map(tampered, fn {key, value} -> Map.put(proof(ctx, base), key, value) end)

    invalid =
      invalid ++
        [
          proof(ctx),
          proof(ctx, Map.put(base, "method", "post")),
          proof(ctx, Map.put(base, "resource", "https://not-allowed.invalid/"))
        ]

    for params <- invalid do
      assert {:error, _} = Redeem.egress(params)

      assert {:error, :invalid_proof} =
               Redeem.egress(proof(ctx, Map.put(base, "nonce", params["nonce"])))
    end

    assert {:error, :timeout} = :gen_tcp.accept(listener, 50)
  end

  test "copy-out requires REDEEM, its own resource, and an empty body", ctx do
    for fields <- [
          %{"method" => "POST"},
          %{"method" => "redeem"},
          %{"resource" => "other"},
          %{"body_b64" => Base.encode64("hi")}
        ] do
      params = proof(ctx, fields)
      assert {:error, :invalid_proof} = Redeem.redeem(params)
      assert {:error, :invalid_proof} = Redeem.redeem(proof(ctx, %{"nonce" => params["nonce"]}))
    end

    assert {:ok, _, _} = Redeem.redeem(proof(ctx, %{"body_b64" => "", "idempotency_key" => ""}))
  end

  test "malformed JSON types and base64 burn well-formed nonces", ctx do
    fields =
      ~w(biscuit audience method resource secret_id body_b64 idempotency_key public_key signature)

    for field <- fields, value <- [nil, 42, true, [], %{}] do
      params = Map.put(proof(ctx), field, value)
      assert {:error, _} = Redeem.redeem(params)
      assert :error = Nonces.consume(params["nonce"])
    end

    for field <- ~w(biscuit audience method resource secret_id public_key signature) do
      for value <- [:missing, ""] do
        params = proof(ctx)

        malformed =
          if value == :missing, do: Map.delete(params, field), else: Map.put(params, field, value)

        assert {:error, _} = Redeem.redeem(malformed)
        assert :error = Nonces.consume(params["nonce"])
      end
    end

    for body <- ["!", "a", "aGk===", "aG k="] do
      params = Map.put(proof(ctx), "body_b64", body)
      assert {:error, _} = Redeem.redeem(params)
      assert :error = Nonces.consume(params["nonce"])
    end
  end

  test "malformed nonces are rejected before consumption", ctx do
    for nonce <- [
          nil,
          42,
          [],
          %{},
          "",
          "abc",
          String.duplicate("A", 64),
          String.duplicate("g", 64)
        ] do
      # Insert malformed keys to make the no-consumption guarantee observable.
      :sys.replace_state(Nonces, &Map.put(&1, nonce, System.monotonic_time(:second) + 60))
      assert {:error, :invalid_proof} = Redeem.redeem(Map.put(proof(ctx), "nonce", nonce))
      assert Map.has_key?(:sys.get_state(Nonces), nonce)
      :sys.replace_state(Nonces, &Map.delete(&1, nonce))
    end
  end

  test "the old four-line signature no longer verifies and burns its nonce", ctx do
    params = proof(ctx)
    old = "mjolnir/redeem/v1\n" <> params["nonce"] <> "\n" <> params["biscuit"] <> "\n" <> ctx.id
    signature = :crypto.sign(:eddsa, :none, old, [ctx.private, :ed25519])

    assert {:error, :invalid_proof} =
             Redeem.redeem(Map.put(params, "signature", Base.encode64(signature)))

    assert :error = Nonces.consume(params["nonce"])
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

  test "the signing frame matches the independent documented golden hex" do
    params = %{
      "biscuit" => "dG9r",
      "nonce" => String.duplicate("ab", 32),
      "audience" => "proxy",
      "method" => "POST",
      "resource" => "https://127.0.0.1/v1",
      "body_b64" => "aGk=",
      "secret_id" => "github-pat",
      "idempotency_key" => "k1"
    }

    golden =
      Base.decode16!(
        "6d6a6f6c6e69722f72656465656d2f763100000000046447397200000040616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261620000000570726f787900000004504f53540000001468747470733a2f2f3132372e302e302e312f76310000002085052e9aab1b67b6622d94a08441b09fd5b7aca61ee360416d70de5da67d86ca0000000a6769746875622d706174000000026b31",
        case: :lower
      )

    assert Redeem.signing_message(params["nonce"], params["biscuit"], params) == golden

    assert Base.encode16(Biscuit.blake3_hash(""), case: :lower) ==
             "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
  end
end
