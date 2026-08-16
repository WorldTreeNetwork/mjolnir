defmodule Mjolnir.API.Auth do
  @moduledoc """
  Authentication plug for the Mjolnir HTTP API.

  Credential paths, checked in this order:

  1. **Sites service tokens** (`Authorization: Bearer mjsk_...`) — scoped
     credentials for unattended publishing. They confer only
     `Mjolnir.Sites.Token.scope/0` and are bound to one IdentiKey fingerprint;
     `Mjolnir.API.SitesRouter` enforces that binding against the request path.
  2. **Localhost bypass** — when `bypass_localhost: true` and the peer is
     loopback. Confers the full control-plane scope set.
  3. **JWT** — `Authorization: Bearer`, then `?token=`, then the `mj_term`
     cookie. A valid JWT confers the full scope set; scopes are ours, not
     the token's. Query/cookie exist because a browser `WebSocket` cannot
     set an Authorization header (mjolnir-wrug.1). `GET /term/:id` stashes
     `?token=` into the cookie and redirects so the JWT is not left in the
     URL. Sites tokens are never accepted from query or cookie.

  Sites tokens are checked *first* so that presenting one always yields the
  narrow scope, even from loopback. A caller holding a scoped CI credential
  should never be silently upgraded to full control-plane access by virtue of
  where it connected from. Nothing here widens the loopback bypass — a request
  with no credential is treated exactly as before.
  """

  import Plug.Conn
  require Logger

  alias Mjolnir.Sites.{Token, TokenStore}

  @behaviour Plug

  @skip_auth_paths ["/api/health"]

  # Cookie `GET /term/:id` sets so the PTY WebSocket can authenticate. The
  # browser WebSocket constructor cannot send Authorization.
  @term_cookie "mj_term"

  @impl true
  def init(opts), do: opts

  @all_scopes "vms:spawn vms:read vms:exec vms:stop pty:connect terminal:read terminal:write snapshots:create snapshots:read snapshots:delete"

  @impl true
  def call(conn, _opts) do
    conn = conn |> fetch_query_params() |> fetch_cookies()

    cond do
      skip_auth?(conn) ->
        conn

      sites_token_presented?(conn) ->
        verify_sites_token(conn)

      localhost_bypass?(conn) ->
        conn
        |> assign(:claims, %{"scope" => @all_scopes})
        |> assign(:user_id, "localhost")

      true ->
        verify_token(conn)
    end
  end

  defp skip_auth?(conn) do
    conn.request_path in @skip_auth_paths or
      String.starts_with?(conn.request_path, "/auth/")
  end

  @doc "Name of the cookie `GET /term/:id` uses to carry a JWT to the PTY socket."
  def term_cookie, do: @term_cookie

  @doc """
  Pull a JWT (not a sites token) from the request.

  Order: `Authorization: Bearer`, `?token=`, `mj_term` cookie. Sites tokens
  in the Bearer header are *not* returned here — they take the sites path
  in `call/2`. Public so the fail-closed policy is unit-testable.
  """
  @spec extract_jwt(Plug.Conn.t()) :: {:ok, String.t()} | :error
  def extract_jwt(conn) do
    conn = conn |> fetch_query_params() |> fetch_cookies()

    cond do
      match?(["Bearer " <> _], get_req_header(conn, "authorization")) ->
        ["Bearer " <> raw] = get_req_header(conn, "authorization")
        if Token.looks_like_token?(raw), do: :error, else: {:ok, raw}

      is_binary(conn.query_params["token"]) and conn.query_params["token"] != "" ->
        {:ok, conn.query_params["token"]}

      is_binary(conn.req_cookies[@term_cookie]) and conn.req_cookies[@term_cookie] != "" ->
        {:ok, conn.req_cookies[@term_cookie]}

      true ->
        :error
    end
  end

  defp sites_token_presented?(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] -> Token.looks_like_token?(raw)
      _ -> false
    end
  end

  # A verified sites token gets ONLY the publish scope — never `@all_scopes`.
  # Every control-plane route calls `Authz.require_scope/2`, so a sites token is
  # rejected with 403 there without those routes needing to know it exists.
  defp verify_sites_token(conn) do
    with ["Bearer " <> raw] <- get_req_header(conn, "authorization"),
         {:ok, token} <- TokenStore.verify(raw) do
      principal = "sites_token:" <> token.id

      conn
      |> assign(:claims, %{"scope" => Token.scope(), "sub" => principal})
      |> assign(:user_id, principal)
      |> assign(:sites_token, token)
    else
      {:error, reason} ->
        # Log the reason for operators; never return it. Distinguishing
        # "unknown id" from "bad secret" to a caller is an enumeration oracle.
        Logger.warning("Sites token rejected: #{inspect(reason)}")
        unauthorized(conn)

      _ ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "invalid_token"}))
    |> halt()
  end

  defp localhost_bypass?(conn) do
    auth_config = Application.get_env(:mjolnir, :auth, [])

    Keyword.get(auth_config, :bypass_localhost, false) &&
      conn.remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]
  end

  defp verify_token(conn) do
    with {:ok, token} <- extract_jwt(conn),
         {:ok, claims} <- safe_verify(token) do
      # Valid JWT = full access. Scopes come from us, not the token.
      # sub is preserved for multi-tenancy (user identity).
      claims = Map.put(claims, "scope", @all_scopes)

      conn
      |> assign(:claims, claims)
      |> assign(:user_id, Map.get(claims, "sub"))
    else
      _ -> unauthenticated(conn)
    end
  end

  # A browser hitting /term without a JWT should bounce through IdentiKey
  # Connect, not see a JSON 401. API and PTY sockets stay 401.
  defp unauthenticated(conn) do
    if String.starts_with?(conn.request_path, "/term/") do
      next = conn.request_path <> query_suffix(conn)
      loc = "/auth/login?next=" <> URI.encode_www_form(next)

      conn
      |> put_resp_header("location", loc)
      |> send_resp(302, "")
      |> halt()
    else
      unauthorized(conn)
    end
  end

  defp query_suffix(%{query_string: q}) when is_binary(q) and q != "", do: "?" <> q
  defp query_suffix(_), do: ""

  # Joken's JWKS hook peeks the header and can raise on a garbage token
  # (Jason.DecodeError). A junk ?token= or mj_term cookie must 401, not 500.
  defp safe_verify(token) do
    Mjolnir.Auth.Token.verify_token(token)
  rescue
    _ -> {:error, :malformed_token}
  end
end
