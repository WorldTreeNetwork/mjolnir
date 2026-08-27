defmodule Mjolnir.API.RouterSecretsTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Mjolnir.API.Router

  @opts Router.init([])

  setup do
    original_auth = Application.get_env(:mjolnir, :auth, [])
    Application.put_env(:mjolnir, :auth, bypass_localhost: true)

    original_dir = Application.get_env(:mjolnir, :deploy_secrets_dir)
    dir = Path.join(System.tmp_dir!(), "router-secrets-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mjolnir, :deploy_secrets_dir, dir)

    app = "secrets-app-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Mjolnir.Deploy.Registry.put(app, %{
        release_snapshot: "rel-1",
        service_vm_id: "svc-1",
        url: "https://x",
        port: 9000,
        owner_id: "alice"
      })

    on_exit(fn ->
      Application.put_env(:mjolnir, :auth, original_auth)

      if original_dir,
        do: Application.put_env(:mjolnir, :deploy_secrets_dir, original_dir),
        else: Application.delete_env(:mjolnir, :deploy_secrets_dir)

      File.rm_rf(dir)
      Mjolnir.Deploy.Registry.delete(app)
    end)

    %{app: app, dir: dir}
  end

  defp request(method, path, body \\ nil) do
    conn = conn(method, path, body && Jason.encode!(body))

    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  test "PUT merges, GET lists names, DELETE unsets", %{app: app, dir: dir} do
    File.write!(
      Path.join(dir, Mjolnir.Deploy.Secrets.slug(app) <> ".json"),
      ~s({"DATABASE_URL":"postgres://x"})
    )

    conn = request(:put, "/api/apps/#{app}/secrets", %{key: "STRIPE_API_KEY", value: "sk_live_x"})
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["set"] == ["STRIPE_API_KEY"]
    assert "DATABASE_URL" in body["keys"]
    assert "STRIPE_API_KEY" in body["keys"]
    refute inspect(body) =~ "sk_live_x"
    refute inspect(body) =~ "postgres://x"

    conn = request(:get, "/api/apps/#{app}/secrets")
    assert conn.status == 200
    listing = Jason.decode!(conn.resp_body)
    assert Enum.sort(listing["keys"]) == ["DATABASE_URL", "STRIPE_API_KEY"]

    conn = request(:delete, "/api/apps/#{app}/secrets/STRIPE_API_KEY")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["unset"] == "STRIPE_API_KEY"
  end

  test "unknown app is 404" do
    conn = request(:put, "/api/apps/no-such-app/secrets", %{key: "FOO", value: "bar"})
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"] == "app_not_found"
  end

  test "rejects a bad key name", %{app: app} do
    conn = request(:put, "/api/apps/#{app}/secrets", %{key: "not-valid", value: "x"})
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "invalid_key"
  end
end
