defmodule Mjolnir.API.LoginRouteTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Mjolnir.API.Router

  @opts Router.init([])
  @vm "01234567-89ab-cdef-0123-456789abcdef"

  defmodule FakeOidc do
    def pkce, do: {"verifier", "challenge"}
    def redirect_uri, do: "https://api.vm.worldtree.network/auth/callback"

    def authorize_url(state, challenge, redirect) do
      {:ok,
       "https://auth.identikey.me/authorize?client_id=mjolnir-term" <>
         "&response_type=code&code_challenge=#{challenge}" <>
         "&redirect_uri=#{URI.encode_www_form(redirect)}&state=#{state}"}
    end

    def exchange_code("good-code", "verifier", _redirect), do: {:ok, "fake.jwt.token"}
    def exchange_code(_, _, _), do: {:error, :bad_code}
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

  test "GET /auth/login 302s to the OP authorize URL with PKCE" do
    conn = request("/auth/login?next=/term/#{@vm}")
    assert conn.status == 302
    [loc] = get_resp_header(conn, "location")
    assert loc =~ "https://auth.identikey.me/authorize"
    assert loc =~ "client_id=mjolnir-term"
    assert loc =~ "code_challenge="
    assert loc =~ "redirect_uri="
    assert loc =~ "state="
  end

  test "GET /auth/callback sets the cookie and redirects to /term" do
    start = request("/auth/login?next=/term/#{@vm}")
    [loc] = get_resp_header(start, "location")
    state = loc |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("state")

    conn = request("/auth/callback?code=good-code&state=#{state}")
    assert conn.status == 302
    [next] = get_resp_header(conn, "location")
    assert next == "/term/#{@vm}"
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
