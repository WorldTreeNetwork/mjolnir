defmodule Mjolnir.Relay.MintTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    bytes = <<0xAB>> <> :binary.copy(<<0x11>>, 31)
    owner = Mjolnir.Deploy.Owner.encode(bytes)
    key = JOSE.JWK.generate_key({:okp, :Ed25519})
    kid = "mintKid1"
    key = JOSE.JWK.merge(key, %{"kid" => kid})
    {_, map} = JOSE.JWK.to_map(key)
    map = Map.new(map, fn {k, v} -> {to_string(k), v} end) |> Map.put("alg", "EdDSA")
    key_path = Path.join(dir, "current.jwk")
    File.write!(key_path, Jason.encode!(map))
    File.chmod!(key_path, 0o600)
    File.chmod!(dir, 0o700)
    env = Path.join(dir, "relay.env")

    File.write!(env, """
    MJOLNIR_RELAY_ENABLED=true
    MJOLNIR_RELAY_HOST=relay.test
    MJOLNIR_RELAY_TOKEN_MAX_TTL=3600
    """)

    %{
      owner: owner,
      env: env,
      key: key_path,
      uid: File.stat!(key_path).uid,
      caller: fn scopes ->
        %{kind: :user, sub: owner, scopes: scopes}
      end
    }
  end

  defp opts(ctx) do
    [env_path: ctx.env, key_path: ctx.key, uid: ctx.uid]
  end

  test "omitted ttl uses the ceiling and the header owner is not an argument", ctx do
    assert {:ok, minted} =
             Mjolnir.Relay.Mint.issue(
               ctx.caller.("relay:join"),
               "standup",
               "alice",
               %{},
               opts(ctx)
             )

    assert minted.root == "t/#{ctx.owner}/standup"
    assert minted.publish == "alice/**"
    assert minted.subscribe == "**"
    assert minted.relay_host == "relay.test"
    assert (minted.expires - System.system_time(:second)) in 3599..3600

    [header_b64, payload_b64, _sig] = String.split(minted.token, ".")
    header = Jason.decode!(Base.url_decode64!(header_b64, padding: false))
    claims = Jason.decode!(Base.url_decode64!(payload_b64, padding: false))
    assert header["alg"] == "EdDSA"
    assert header["kid"] == "mintKid1"

    assert Map.keys(claims) |> Enum.sort() == [
             "exp",
             "iat",
             "jti",
             "publish",
             "root",
             "subscribe"
           ]

    assert claims["root"] == minted.root
    assert claims["publish"] == ["alice/**"]
    assert claims["subscribe"] == ["**"]
    assert claims["exp"] == minted.expires
    assert String.length(claims["jti"]) == 22
    refute Map.has_key?(claims, "aud")
  end

  test "ttl edges are 400", ctx do
    caller = ctx.caller.("relay:join")

    for body <- [
          %{"ttl" => 0},
          %{"ttl" => -1},
          %{"ttl" => 3601},
          %{"ttl" => "30"},
          %{"ttl" => 1.5}
        ] do
      assert {:error, 400, "bad_ttl"} =
               Mjolnir.Relay.Mint.issue(caller, "standup", "alice", body, opts(ctx))
    end
  end

  test "other principals and a bad sub are 403", ctx do
    for kind <- [:operator, :sites, :capability, :ceremony] do
      assert {:error, 403, _} =
               Mjolnir.Relay.Mint.issue(
                 %{kind: kind, sub: ctx.owner, scopes: "relay:join"},
                 "r",
                 "p",
                 %{},
                 opts(ctx)
               )
    end

    assert {:error, 403, _} =
             Mjolnir.Relay.Mint.issue(
               %{kind: :user, sub: "not-an-owner", scopes: "relay:join"},
               "r",
               "p",
               %{},
               opts(ctx)
             )
  end

  test "bad segments are 400", ctx do
    caller = ctx.caller.("relay:join")

    for bad <- ["", String.duplicate("a", 65), ".", "..", "a/b", "a\\b", "*", "a\n", "room\n"] do
      assert {:error, 400, "bad_segment"} =
               Mjolnir.Relay.Mint.issue(caller, bad, "alice", %{}, opts(ctx))

      assert {:error, 400, "bad_segment"} =
               Mjolnir.Relay.Mint.issue(caller, "standup", bad, %{}, opts(ctx))
    end
  end

  test "disabled and a group-readable key are 503", ctx do
    File.write!(ctx.env, "MJOLNIR_RELAY_ENABLED=false\nMJOLNIR_RELAY_HOST=relay.test\n")

    assert {:error, 503, _} =
             Mjolnir.Relay.Mint.issue(ctx.caller.("relay:join"), "r", "p", %{}, opts(ctx))

    File.write!(ctx.env, "MJOLNIR_RELAY_ENABLED=true\nMJOLNIR_RELAY_HOST=relay.test\n")
    File.chmod!(ctx.key, 0o640)

    assert {:error, 503, _} =
             Mjolnir.Relay.Mint.issue(ctx.caller.("relay:join"), "r", "p", %{}, opts(ctx))
  end

  test "a missing env file and an unset host are 503", ctx do
    missing = [env_path: Path.join(ctx.env, "no-such.env"), key_path: ctx.key, uid: ctx.uid]

    assert {:error, 503, "relay_unavailable"} =
             Mjolnir.Relay.Mint.issue(ctx.caller.("relay:join"), "r", "p", %{}, missing)

    File.write!(ctx.env, "MJOLNIR_RELAY_ENABLED=true\n")

    assert {:error, 503, "relay_unavailable"} =
             Mjolnir.Relay.Mint.issue(ctx.caller.("relay:join"), "r", "p", %{}, opts(ctx))
  end

  test "a trailing space and one pair of quotes parse, and a bad ceiling is 503", ctx do
    File.write!(ctx.env, """
    MJOLNIR_RELAY_ENABLED=true
    MJOLNIR_RELAY_HOST="relay.test"
    MJOLNIR_RELAY_TOKEN_MAX_TTL=3600 
    """)

    assert {:ok, minted} =
             Mjolnir.Relay.Mint.issue(ctx.caller.("relay:join"), "r", "p", %{}, opts(ctx))

    assert minted.relay_host == "relay.test"
    assert (minted.expires - System.system_time(:second)) in 3599..3600

    File.write!(ctx.env, """
    MJOLNIR_RELAY_ENABLED=true
    MJOLNIR_RELAY_HOST=relay.test
    MJOLNIR_RELAY_TOKEN_MAX_TTL=60
    """)

    assert {:ok, short} =
             Mjolnir.Relay.Mint.issue(ctx.caller.("relay:join"), "r", "p", %{}, opts(ctx))

    assert (short.expires - System.system_time(:second)) in 59..60

    assert {:error, 400, "bad_ttl"} =
             Mjolnir.Relay.Mint.issue(
               ctx.caller.("relay:join"),
               "r",
               "p",
               %{"ttl" => 61},
               opts(ctx)
             )

    File.write!(ctx.env, """
    MJOLNIR_RELAY_ENABLED=true
    MJOLNIR_RELAY_HOST=relay.test
    MJOLNIR_RELAY_TOKEN_MAX_TTL=nope
    """)

    assert {:error, 503, "relay_unavailable"} =
             Mjolnir.Relay.Mint.issue(ctx.caller.("relay:join"), "r", "p", %{}, opts(ctx))
  end

  test "a key with d and no x, or with no d, is 503 and is not logged", ctx do
    raw = Jason.decode!(File.read!(ctx.key))

    File.write!(ctx.key, Jason.encode!(Map.delete(raw, "x")))

    log =
      capture_log(fn ->
        assert {:error, 503, "relay_unavailable"} =
                 Mjolnir.Relay.Mint.issue(ctx.caller.("relay:join"), "r", "p", %{}, opts(ctx))
      end)

    refute log =~ raw["d"]

    File.write!(ctx.key, Jason.encode!(Map.delete(raw, "d")))

    assert {:error, 503, "relay_unavailable"} =
             Mjolnir.Relay.Mint.issue(ctx.caller.("relay:join"), "r", "p", %{}, opts(ctx))
  end

  test "missing key, wrong uid, group-writable directory, and no kid are 503", ctx do
    missing = [env_path: ctx.env, key_path: Path.join(ctx.key, "absent.jwk"), uid: ctx.uid]

    assert {:error, 503, "relay_unavailable"} =
             Mjolnir.Relay.Mint.issue(ctx.caller.("relay:join"), "r", "p", %{}, missing)

    assert {:error, 503, "relay_unavailable"} =
             Mjolnir.Relay.Mint.issue(
               ctx.caller.("relay:join"),
               "r",
               "p",
               %{},
               Keyword.put(opts(ctx), :uid, ctx.uid + 1)
             )

    File.chmod!(Path.dirname(ctx.key), 0o720)

    assert {:error, 503, "relay_unavailable"} =
             Mjolnir.Relay.Mint.issue(ctx.caller.("relay:join"), "r", "p", %{}, opts(ctx))

    File.chmod!(Path.dirname(ctx.key), 0o700)
    raw = Jason.decode!(File.read!(ctx.key))
    File.write!(ctx.key, Jason.encode!(Map.delete(raw, "kid")))

    assert {:error, 503, "relay_unavailable"} =
             Mjolnir.Relay.Mint.issue(ctx.caller.("relay:join"), "r", "p", %{}, opts(ctx))
  end

  test "the log line has no token", ctx do
    log =
      capture_log(fn ->
        assert {:ok, minted} =
                 Mjolnir.Relay.Mint.issue(
                   ctx.caller.("relay:join"),
                   "standup",
                   "alice",
                   %{},
                   opts(ctx)
                 )

        send(self(), {:token, minted.token})
      end)

    assert_received {:token, token}
    refute log =~ token
  end
end
