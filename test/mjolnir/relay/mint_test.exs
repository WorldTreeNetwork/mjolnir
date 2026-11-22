defmodule Mjolnir.Relay.MintTest do
  use ExUnit.Case, async: false

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

  test "mints a 300 second token and ignores the header owner", ctx do
    assert {:ok, token} =
             Mjolnir.Relay.Mint.issue(ctx.caller.("relay:join"), "standup", "alice", %{}, opts(ctx))

    assert token.root == "t/#{ctx.owner}/standup"
    assert token.publish == "alice/**"
    assert token.subscribe == "**"
    assert token.relay_host == "relay.test"
    assert token.expires - System.system_time(:second) in 299..300
  end

  test "ttl edges are 400", ctx do
    caller = ctx.caller.("relay:join")

    for body <- [%{"ttl" => 0}, %{"ttl" => -1}, %{"ttl" => 3601}, %{"ttl" => "30"}, %{"ttl" => 1.5}] do
      assert {:error, 400, "bad_ttl"} = Mjolnir.Relay.Mint.issue(caller, "standup", "alice", body, opts(ctx))
    end
  end

  test "other principals and a bad sub are 403", ctx do
    for kind <- [:operator, :sites, :capability, :ceremony] do
      assert {:error, 403, _} =
               Mjolnir.Relay.Mint.issue(%{kind: kind, sub: ctx.owner, scopes: "relay:join"}, "r", "p", %{}, opts(ctx))
    end

    assert {:error, 403, _} =
             Mjolnir.Relay.Mint.issue(%{kind: :user, sub: "not-an-owner", scopes: "relay:join"}, "r", "p", %{}, opts(ctx))
  end

  test "bad segments are 400", ctx do
    caller = ctx.caller.("relay:join")

    for bad <- ["", String.duplicate("a", 65), ".", "..", "a/b", "a\\b", "*", "a\n", "room\n"] do
      assert {:error, 400, "bad_segment"} =
               Mjolnir.Relay.Mint.issue(caller, bad, "alice", %{}, opts(ctx))
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
end
