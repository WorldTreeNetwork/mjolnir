defmodule Mjolnir.API.LoginRouteTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Mjolnir.API.Router

  @opts Router.init([])
  @vm "01234567-89ab-cdef-0123-456789abcdef"

  defmodule FakeOidc do
    def start_device(_challenge) do
      {:ok,
       %{
         device_code: "dc",
         user_code: "ABCD-EFGH",
         verification_uri: "https://connect.identikey.io/device",
         verification_uri_complete: "https://connect.identikey.io/device?user_code=ABCD-EFGH",
         interval: 1,
         expires_in: 600
       }}
    end

    def poll_token("dc", _verifier), do: {:ok, "fake.jwt.token"}
    def poll_token(_, _), do: :pending
  end

  setup do
    original = Application.get_env(:mjolnir, :auth, [])

    Application.put_env(
      :mjolnir,
      :auth,
      original
      |> Keyword.put(:bypass_localhost, true)
      |> Keyword.put(:oidc_mod, FakeOidc)
    )

    unless Process.whereis(Mjolnir.Auth.Login) do
      start_supervised!(Mjolnir.Auth.Login)
    end

    on_exit(fn -> Application.put_env(:mjolnir, :auth, original) end)
    :ok
  end

  defp request(path) do
    conn(:get, path)
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> Router.call(@opts)
  end

  test "GET /auth/login serves the waiting room and a Connect URL" do
    conn = request("/auth/login?next=/term/#{@vm}")
    assert conn.status == 200
    assert conn.resp_body =~ "IDENTIKEY CONNECT"
    assert conn.resp_body =~ "connect.identikey.io"
    assert conn.resp_body =~ "/auth/wait/"
  end

  test "GET /auth/wait sets the cookie and returns next when Connect is done" do
    start = request("/auth/login?next=/term/#{@vm}")
    assert start.status == 200
    [id] = Regex.run(~r{const ID = "([0-9a-f]+)"}, start.resp_body, capture: :all_but_first)

    # First poll is last_poll=0 so it hits Keycloak immediately.
    conn = request("/auth/wait/#{id}")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == true
    assert body["next"] == "/term/#{@vm}"
    assert conn.resp_cookies[Mjolnir.API.Auth.term_cookie()].value == "fake.jwt.token"
  end

  test "an unauthenticated /term request from a non-local IP redirects to login" do
    original = Application.get_env(:mjolnir, :auth, [])
    Application.put_env(:mjolnir, :auth, Keyword.put(original, :bypass_localhost, false))

    conn =
      conn(:get, "/term/#{@vm}")
      |> Map.put(:remote_ip, {10, 0, 0, 1})
      |> Router.call(@opts)

    assert conn.status == 302
    [loc] = get_resp_header(conn, "location")
    assert loc =~ "/auth/login?next="
    assert loc =~ @vm
  end
end
