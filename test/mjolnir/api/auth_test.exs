defmodule Mjolnir.API.AuthTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Mjolnir.API.Auth

  defp call_auth(conn) do
    Auth.call(conn, Auth.init([]))
  end

  describe "health endpoint bypass" do
    test "skips auth for /api/health" do
      conn =
        conn(:get, "/api/health")
        |> call_auth()

      refute conn.halted
      refute conn.assigns[:claims]
    end
  end

  describe "localhost bypass" do
    setup do
      original = Application.get_env(:mjolnir, :auth, [])
      on_exit(fn -> Application.put_env(:mjolnir, :auth, original) end)
      :ok
    end

    test "grants all scopes when bypass_localhost is true and request is from localhost" do
      Application.put_env(:mjolnir, :auth, bypass_localhost: true)

      conn =
        conn(:get, "/api/vms")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> call_auth()

      refute conn.halted
      assert conn.assigns[:claims]["scope"] =~ "vms:read"
      assert conn.assigns[:claims]["scope"] =~ "vms:spawn"
    end

    test "grants all scopes for IPv6 localhost" do
      Application.put_env(:mjolnir, :auth, bypass_localhost: true)

      conn =
        conn(:get, "/api/vms")
        |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 0, 0, 1})
        |> call_auth()

      refute conn.halted
      assert conn.assigns[:claims]
    end

    test "sets user_id to 'localhost' in assigns" do
      Application.put_env(:mjolnir, :auth, bypass_localhost: true)

      conn =
        conn(:get, "/api/vms")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> call_auth()

      assert conn.assigns[:user_id] == "localhost"
    end

    test "returns 401 when bypass_localhost is false and no token provided" do
      Application.put_env(:mjolnir, :auth, bypass_localhost: false)

      conn =
        conn(:get, "/api/vms")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> call_auth()

      assert conn.halted
      assert conn.status == 401
    end

    test "returns 401 when bypass_localhost is true but request is not from localhost" do
      Application.put_env(:mjolnir, :auth, bypass_localhost: true)

      conn =
        conn(:get, "/api/vms")
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> call_auth()

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "bearer token" do
    setup do
      original = Application.get_env(:mjolnir, :auth, [])
      Application.put_env(:mjolnir, :auth, bypass_localhost: false)
      on_exit(fn -> Application.put_env(:mjolnir, :auth, original) end)
      :ok
    end

    test "returns 401 when no authorization header" do
      conn =
        conn(:get, "/api/vms")
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> call_auth()

      assert conn.halted
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "invalid_token"
    end

    test "returns 401 with invalid token" do
      conn =
        conn(:get, "/api/vms")
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> put_req_header("authorization", "Bearer invalid.token.here")
        |> call_auth()

      assert conn.halted
      assert conn.status == 401
    end
  end
end
