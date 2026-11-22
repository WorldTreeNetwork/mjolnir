defmodule Mjolnir.API.RelayMintRouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Mjolnir.API.Router
  alias Mjolnir.Auth.{JwksCache, JwksStrategy}

  @opts Router.init([])
  @issuer "https://relay-mint.example"

  setup do
    dir = Path.join(System.tmp_dir!(), "relay-mint-router-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    owner = Mjolnir.Deploy.Owner.encode(<<7, 7>> <> :binary.copy(<<9>>, 30))
    key = JOSE.JWK.generate_key({:okp, :Ed25519})
    {_, map} = JOSE.JWK.to_map(JOSE.JWK.merge(key, %{"kid" => "mintKid1"}))
    map = Map.new(map, fn {k, v} -> {to_string(k), v} end) |> Map.put("alg", "EdDSA")
    key_path = Path.join(dir, "current.jwk")
    File.write!(key_path, Jason.encode!(map))
    File.chmod!(key_path, 0o600)
    env = Path.join(dir, "relay.env")

    File.write!(env, """
    MJOLNIR_RELAY_ENABLED=true
    MJOLNIR_RELAY_HOST=relay.test
    MJOLNIR_RELAY_TOKEN_MAX_TTL=3600
    """)

    original = %{
      auth: Application.get_env(:mjolnir, :auth),
      test_operator: Application.get_env(:mjolnir, :test_operator),
      key: Application.get_env(:mjolnir, :relay_mint_key_path),
      env: Application.get_env(:mjolnir, :relay_mint_env_path),
      uid: Application.get_env(:mjolnir, :relay_mint_uid)
    }

    Application.put_env(:mjolnir, :relay_mint_uid, File.stat!(key_path).uid)
    Application.put_env(:mjolnir, :relay_mint_key_path, key_path)
    Application.put_env(:mjolnir, :relay_mint_env_path, env)
    Application.put_env(:mjolnir, :test_operator, false)

    Application.put_env(:mjolnir, :auth,
      issuer: @issuer,
      bypass_localhost: false,
      require_audience: false
    )

    if Process.whereis(Mjolnir.Supervisor) && Process.whereis(JwksStrategy) do
      :ok = Supervisor.terminate_child(Mjolnir.Supervisor, JwksStrategy)

      on_exit(fn ->
        if Process.whereis(Mjolnir.Supervisor) && !Process.whereis(JwksStrategy) do
          Supervisor.restart_child(Mjolnir.Supervisor, JwksStrategy)
        end
      end)
    end

    on_exit(fn ->
      restore(:auth, original.auth)
      restore(:test_operator, original.test_operator)
      restore(:relay_mint_key_path, original.key)
      restore(:relay_mint_env_path, original.env)
      restore(:relay_mint_uid, original.uid)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir, owner: owner}
  end

  test "an operator is forbidden on the user-only mint" do
    Application.put_env(:mjolnir, :test_operator, true)
    Application.put_env(:mjolnir, :auth, bypass_localhost: true)

    conn =
      conn(
        :post,
        "/api/relay/rooms/standup/participants/alice/token",
        Jason.encode!(%{"owner_id" => "nope"})
      )
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-owner-id", "also-nope")
      |> Router.call(@opts)

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"] == "forbidden"
  end

  test "a user mint ignores x-owner-id and body owner_id and does not store the token", ctx do
    {private, public} = issuer_key()
    opts = JwksStrategy.init_opts(issuer: @issuer, auth_dir: ctx.dir)
    assert {:ok, _} = JwksCache.persist(%{"keys" => [public]}, opts)

    start_supervised!(
      {JwksStrategy,
       opts
       |> Keyword.put(:time_interval, 60_000)
       |> Keyword.put(:http_adapter, fn _ -> {:error, :econnrefused} end)}
    )

    token =
      Joken.generate_and_sign!(
        %{},
        %{"iss" => @issuer, "sub" => ctx.owner, "exp" => Joken.current_time() + 600},
        Joken.Signer.create("ES256", elem(JOSE.JWK.to_map(private), 1), %{"kid" => "A"})
      )

    conn =
      conn(
        :post,
        "/api/relay/rooms/standup/participants/alice/token",
        Jason.encode!(%{"owner_id" => "not-the-caller"})
      )
      |> Map.put(:remote_ip, {1, 2, 3, 4})
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("x-owner-id", "not-the-caller")
      |> Router.call(@opts)

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body = Jason.decode!(conn.resp_body)
    assert body["root"] == "t/#{ctx.owner}/standup"
    assert body["publish"] == "alice/**"
    refute body["root"] =~ "not-the-caller"
  end

  defp issuer_key do
    private = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, public} = JOSE.JWK.to_public_map(private)
    {private, Map.merge(public, %{"kid" => "A", "alg" => "ES256", "use" => "sig"})}
  end

  defp restore(key, nil), do: Application.delete_env(:mjolnir, key)
  defp restore(key, value), do: Application.put_env(:mjolnir, key, value)
end
