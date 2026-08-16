defmodule Mjolnir.API.AuthTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Mjolnir.API.Auth

  defp call_auth(conn) do
    Auth.call(conn, Auth.init([]))
  end

  defp put_auth(overrides) do
    current = Application.get_env(:mjolnir, :auth, [])
    Application.put_env(:mjolnir, :auth, Keyword.merge(current, overrides))
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
      put_auth(bypass_localhost: true)

      conn =
        conn(:get, "/api/vms")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> call_auth()

      refute conn.halted
      assert conn.assigns[:claims]["scope"] =~ "vms:read"
      assert conn.assigns[:claims]["scope"] =~ "vms:spawn"
    end

    test "grants all scopes for IPv6 localhost" do
      put_auth(bypass_localhost: true)

      conn =
        conn(:get, "/api/vms")
        |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 0, 0, 1})
        |> call_auth()

      refute conn.halted
      assert conn.assigns[:claims]
    end

    test "sets user_id to 'localhost' in assigns" do
      put_auth(bypass_localhost: true)

      conn =
        conn(:get, "/api/vms")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> call_auth()

      assert conn.assigns[:user_id] == "localhost"
    end

    test "returns 401 when bypass_localhost is false and no token provided" do
      put_auth(bypass_localhost: false)

      conn =
        conn(:get, "/api/vms")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> call_auth()

      assert conn.halted
      assert conn.status == 401
    end

    test "returns 401 when bypass_localhost is true but request is not from localhost" do
      put_auth(bypass_localhost: true)

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
      put_auth(bypass_localhost: false)
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

    test "redirects an unauthenticated /term request to IdentiKey login" do
      conn =
        conn(:get, "/term/01234567-89ab-cdef-0123-456789abcdef?session=main")
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> call_auth()

      assert conn.halted
      assert conn.status == 302
      [loc] = get_resp_header(conn, "location")
      assert loc =~ "/auth/login?next="
      assert loc =~ "01234567-89ab-cdef-0123-456789abcdef"
    end

    test "still 401s API requests — they are not a browser login bounce" do
      conn =
        conn(:get, "/api/vms")
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> call_auth()

      assert conn.status == 401
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

  describe "extract_jwt/1 (mjolnir-wrug.1)" do
    test "prefers the Bearer header over query and cookie" do
      conn =
        conn(:get, "/api/vms?token=from-query")
        |> put_req_header("authorization", "Bearer from-header")
        |> put_req_cookie(Auth.term_cookie(), "from-cookie")

      assert {:ok, "from-header"} = Auth.extract_jwt(conn)
    end

    test "falls back to ?token= when there is no header" do
      conn = conn(:get, "/term/x?token=from-query")
      assert {:ok, "from-query"} = Auth.extract_jwt(conn)
    end

    test "falls back to the mj_term cookie" do
      conn =
        conn(:get, "/api/vms/x/pty")
        |> put_req_cookie(Auth.term_cookie(), "from-cookie")

      assert {:ok, "from-cookie"} = Auth.extract_jwt(conn)
    end

    test "refuses a sites token in the Bearer header so it cannot be widened" do
      # Sites tokens are mjsk_... and take the narrow sites path in call/2.
      # extract_jwt must not hand them to the JWT verifier.
      conn =
        conn(:get, "/api/vms")
        |> put_req_header("authorization", "Bearer mjsk_thisisnotajwt")

      assert :error = Auth.extract_jwt(conn)
    end

    test "empty query token is not a credential" do
      conn = conn(:get, "/term/x?token=")
      assert :error = Auth.extract_jwt(conn)
    end
  end
end
