defmodule Mjolnir.API.Auth do
  @moduledoc """
  Authentication plug for the Mjolnir HTTP API.

  Three credential paths, checked in this order:

  1. **Sites service tokens** (`Authorization: Bearer mjsk_...`) — scoped
     credentials for unattended publishing. They confer only
     `Mjolnir.Sites.Token.scope/0` and are bound to one IdentiKey fingerprint;
     `Mjolnir.API.SitesRouter` enforces that binding against the request path.
  2. **Localhost bypass** — when `bypass_localhost: true` and the peer is
     loopback. Confers the full control-plane scope set.
  3. **JWT bearer tokens** — verified via `Mjolnir.Auth.Token`. A valid JWT also
     confers the full scope set; scopes are ours, not the token's.

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

  @impl true
  def init(opts), do: opts

  @all_scopes "vms:spawn vms:read vms:exec vms:stop pty:connect terminal:read terminal:write snapshots:create snapshots:read snapshots:delete"

  @impl true
  def call(conn, _opts) do
    cond do
      conn.request_path in @skip_auth_paths ->
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
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- Mjolnir.Auth.Token.verify_token(token) do
      # Valid JWT = full access. Scopes come from us, not the token.
      # sub is preserved for multi-tenancy (user identity).
      claims = Map.put(claims, "scope", @all_scopes)

      conn
      |> assign(:claims, claims)
      |> assign(:user_id, Map.get(claims, "sub"))
    else
      _ -> unauthorized(conn)
    end
  end
end
