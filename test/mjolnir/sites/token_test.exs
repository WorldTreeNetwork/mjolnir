defmodule Mjolnir.Sites.TokenTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Sites.Token

  @fp "9W3eTrPJoS4R2kXuB6Ny"

  describe "mint/2 and parse/1" do
    test "round-trips through the wire format" do
      {token, plaintext} = Token.mint(@fp)

      assert String.starts_with?(plaintext, "mjsk_")
      assert {:ok, {id, secret}} = Token.parse(plaintext)
      assert id == token.id
      assert Token.secret_valid?(token, secret)
    end

    test "the id is lowercase hex and the secret is high-entropy" do
      {token, plaintext} = Token.mint(@fp)
      {:ok, {id, secret}} = Token.parse(plaintext)

      assert id =~ ~r/^[a-f0-9]{16}$/
      assert token.id == id
      # 32 raw bytes in unpadded base64url.
      assert byte_size(secret) == 43
      assert {:ok, raw} = Base.url_decode64(secret, padding: false)
      assert byte_size(raw) == 32
    end

    test "secrets containing base64url underscores still parse" do
      # base64url's alphabet includes `_`, so parsing must split on at most
      # three parts or a secret would be truncated.
      secret = "aa_bb_cc-dd"
      assert {:ok, {"deadbeef", ^secret}} = Token.parse("mjsk_deadbeef_" <> secret)
    end

    test "every mint is unique" do
      ids = for _ <- 1..50, do: elem(Token.mint(@fp), 0).id
      assert length(Enum.uniq(ids)) == 50
    end

    test "rejects malformed credentials" do
      assert :error = Token.parse("not-a-token")
      assert :error = Token.parse("mjsk_")
      assert :error = Token.parse("mjsk_abc")
      assert :error = Token.parse("mjsk__secret")
      assert :error = Token.parse("bearer_abc_def")
      assert :error = Token.parse(nil)
    end

    test "looks_like_token? distinguishes sites tokens from JWTs" do
      {_t, plaintext} = Token.mint(@fp)
      assert Token.looks_like_token?(plaintext)
      # A JWT — base64 of `{"alg"...` always begins `ey`.
      refute Token.looks_like_token?("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.sig")
      refute Token.looks_like_token?("")
    end
  end

  describe "secret storage" do
    test "the struct never carries the plaintext secret" do
      {token, plaintext} = Token.mint(@fp)
      {:ok, {_id, secret}} = Token.parse(plaintext)

      serialized = inspect(token) <> Jason.encode!(Token.to_json(token))

      refute serialized =~ secret
      refute serialized =~ plaintext
      assert token.secret_hash == Token.hash_secret(secret)
    end

    test "secret_valid? rejects a wrong secret" do
      {token, _plaintext} = Token.mint(@fp)
      refute Token.secret_valid?(token, "wrong-secret")
      refute Token.secret_valid?(token, "")
    end

    test "secret_valid? compares hashes, so inputs of any length are safe" do
      {token, _plaintext} = Token.mint(@fp)
      # Would raise if a raw secure_compare saw mismatched sizes.
      refute Token.secret_valid?(token, String.duplicate("x", 5000))
      refute Token.secret_valid?(token, "x")
    end

    test "hash_secret is stable and not the identity" do
      assert Token.hash_secret("abc") == Token.hash_secret("abc")
      refute Token.hash_secret("abc") == "abc"
      assert Token.hash_secret("abc") != Token.hash_secret("abd")
      # Base64 of SHA-256 is always 44 characters.
      assert String.length(Token.hash_secret("abc")) == 44
    end
  end

  describe "expiry and revocation" do
    test "a token with no expiry never expires" do
      {token, _} = Token.mint(@fp)
      refute Token.expired?(token)
      refute Token.expired?(token, DateTime.add(DateTime.utc_now(), 100_000, :second))
    end

    test "expired? flips at the boundary" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {token, _} = Token.mint(@fp, expires_at: now)

      refute Token.expired?(token, DateTime.add(now, -1, :second))
      # Expiry is inclusive: at the instant it expires, it is expired.
      assert Token.expired?(token, now)
      assert Token.expired?(token, DateTime.add(now, 1, :second))
    end

    test "revoked? tracks revoked_at" do
      {token, _} = Token.mint(@fp)
      refute Token.revoked?(token)
      assert Token.revoked?(%{token | revoked_at: DateTime.utc_now()})
    end
  end

  describe "authorizes?/3" do
    test "a fingerprint-bound token permits only its own fingerprint" do
      {token, _} = Token.mint(@fp)
      assert Token.authorizes?(token, @fp, "blog")
      assert Token.authorizes?(token, @fp, nil)
      refute Token.authorizes?(token, "someOtherFingerprint", "blog")
    end

    test "a site-bound token permits only its own site" do
      {token, _} = Token.mint(@fp, site_name: "blog")
      assert Token.authorizes?(token, @fp, "blog")
      refute Token.authorizes?(token, @fp, "secrets")
      # Routes with no site in the path are scoped by fingerprint alone.
      assert Token.authorizes?(token, @fp, nil)
    end

    test "a site binding does not rescue a wrong fingerprint" do
      {token, _} = Token.mint(@fp, site_name: "blog")
      refute Token.authorizes?(token, "otherFp", "blog")
    end
  end

  describe "scope" do
    test "confers only sites:publish, never control-plane scopes" do
      assert Token.scope() == "sites:publish"

      scopes = String.split(Token.scope(), " ", trim: true)

      for forbidden <- ~w(vms:spawn vms:read vms:exec vms:stop pty:connect
                          terminal:read terminal:write snapshots:create
                          snapshots:read snapshots:delete) do
        refute forbidden in scopes
      end
    end
  end

  describe "serialization" do
    test "round-trips through JSON" do
      expires = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      {token, _} = Token.mint(@fp, site_name: "blog", expires_at: expires, description: "ci")

      assert {:ok, decoded} =
               token |> Token.to_json() |> Jason.encode!() |> Jason.decode!() |> Token.from_json()

      assert decoded == token
    end

    test "rejects corrupt records rather than inventing a token" do
      assert {:error, :invalid_token_record} = Token.from_json(%{})
      assert {:error, :invalid_token_record} = Token.from_json(%{"id" => "abc"})
      assert {:error, :invalid_token_record} = Token.from_json("not a map")

      assert {:error, :invalid_token_record} =
               Token.from_json(%{
                 "id" => "abc",
                 "secret_hash" => "h",
                 "identikey_fp" => @fp,
                 "created_at" => "not-a-date"
               })
    end
  end
end
