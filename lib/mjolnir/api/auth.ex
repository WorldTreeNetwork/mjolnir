defmodule Mjolnir.API.Auth do
  @moduledoc """
  Authentication plug for the Mjolnir HTTP API.

  Credential paths, checked in this order:

  1. **Sites service tokens** (`Authorization: Bearer mjsk_...`) — scoped
     credentials for unattended publishing. They confer only
     `Mjolnir.Sites.Token.scope/0` and are bound to one IdentiKey fingerprint;
     `Mjolnir.API.SitesRouter` enforces that binding against the request path.
  2. **Operator socket** — the Unix-socket pipeline
     (`Mjolnir.API.OperatorPipeline`) sets `:mjolnir_operator`. That is the
     break-glass principal. A TCP peer address is not a principal.
     `MJOLNIR_AUTH_BYPASS_LOCALHOST` does not grant this. Dev and test opt
     in with `:dev_operator` / `:test_operator` so local Plug tests still
     run; a production release sets neither.
  3. **Capability token** — `Authorization: Bearer biscuit:<base64>`.
     Parsed against `MJOLNIR_BISCUIT_PUBLIC_HEX`. Confers no scopes. The
     route checks `right(<resource>, <operation>)` before it acts.
  4. **JWT** — `Authorization: Bearer`, then `?token=`, then the `mj_term`
     cookie. A valid JWT confers the full scope set; scopes are ours, not
     the token's. Query/cookie exist because a browser `WebSocket` cannot
     set an Authorization header (mjolnir-wrug.1). `GET /term/:id` stashes
     `?token=` into the cookie and redirects so the JWT is not left in the
     URL. Sites tokens are never accepted from query or cookie. A `sub` of
     `localhost` or `sites_token:…` is rejected. When `:audience` is
     configured, the token must carry `aud` naming one of those clients.
     `:require_audience` set to false accepts a token that omits `aud`.
     A wrong `aud` still fails. `:audience` is a string or a list.

  Sites tokens are checked *first* so that presenting one always yields the
  narrow scope, even on the operator socket.
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

      public_read?(conn) ->
        conn
        |> assign(:principal_kind, :public)
        |> assign(:user_id, nil)

      sites_token_presented?(conn) ->
        verify_sites_token(conn)

      operator_conn?(conn) ->
        conn
        |> assign(:principal_kind, :operator)
        |> assign(:claims, %{"scope" => @all_scopes})
        |> assign(:user_id, "localhost")

      biscuit_presented?(conn) ->
        verify_biscuit(conn)

      ceremony?(conn) ->
        # Challenge / redeem / egress authenticate inside the handler.
        # They do not inherit a scope set from the TCP peer.
        conn
        |> assign(:principal_kind, :ceremony)
        |> assign(:claims, %{"scope" => ""})
        |> assign(:user_id, nil)

      true ->
        verify_token(conn)
    end
  end

  @doc "True when this connection is the operator principal."
  @spec operator?(Plug.Conn.t()) :: boolean()
  def operator?(conn), do: conn.assigns[:principal_kind] == :operator

  @doc "True when this connection presented a Biscuit capability token."
  @spec capability?(Plug.Conn.t()) :: boolean()
  def capability?(conn), do: conn.assigns[:principal_kind] == :capability

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
      |> assign(:principal_kind, :sites)
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

  # Peer address is not a principal. The old bypass flag still exists so
  # dev and the test suite can opt in, and only there.
  defp operator_conn?(conn) do
    conn.private[:mjolnir_operator] == true or
      (loopback?(conn) and bypass_enabled?() and local_dev_operator?())
  end

  defp loopback?(conn) do
    conn.remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]
  end

  defp bypass_enabled? do
    Application.get_env(:mjolnir, :auth, [])
    |> Keyword.get(:bypass_localhost, false)
  end

  defp local_dev_operator? do
    Application.get_env(:mjolnir, :test_operator, false) or
      Application.get_env(:mjolnir, :dev_operator, false)
  end

  defp public_read?(conn) do
    conn.method == "GET" and conn.request_path == "/api/sites/aliases/lookup"
  end

  defp ceremony?(conn) do
    conn.method == "POST" and
      conn.request_path in ["/api/secrets/challenge", "/api/secrets/redeem", "/api/egress"]
  end

  defp biscuit_presented?(conn) do
    match?(["Bearer biscuit:" <> _], get_req_header(conn, "authorization"))
  end

  defp verify_biscuit(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer biscuit:" <> raw] ->
        with {:ok, bytes} <- Base.decode64(raw, padding: false) |> biscuit_padding(raw),
             {:ok, public} <- biscuit_public(),
             :ok <- Mjolnir.Biscuit.parse(bytes, public) do
          conn
          |> assign(:principal_kind, :capability)
          |> assign(:claims, %{"scope" => ""})
          |> assign(:user_id, "capability")
          |> assign(:biscuit, bytes)
        else
          _ -> unauthorized(conn)
        end

      _ ->
        unauthorized(conn)
    end
  end

  defp biscuit_padding({:ok, bytes}, _), do: {:ok, bytes}

  defp biscuit_padding(:error, raw) do
    case Base.decode64(raw) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :error
    end
  end

  defp biscuit_public do
    case Application.get_env(:mjolnir, :biscuit_public_hex) do
      hex when is_binary(hex) and hex != "" -> {:ok, hex}
      _ -> :error
    end
  end

  defp verify_token(conn) do
    with {:ok, token} <- extract_jwt(conn),
         {:ok, claims} <- safe_verify(token),
         :ok <- reject_reserved_sub(claims),
         :ok <- audience_ok?(claims) do
      # Valid JWT = full access. Scopes come from us, not the token.
      # sub is preserved for multi-tenancy (user identity).
      claims = Map.put(claims, "scope", @all_scopes)
      sub = Map.get(claims, "sub")

      conn
      |> assign(:principal_kind, :user)
      |> assign(:claims, claims)
      |> assign(:user_id, sub)
    else
      _ -> unauthenticated(conn)
    end
  end

  defp reject_reserved_sub(%{"sub" => sub}) when is_binary(sub) do
    cond do
      sub in ["localhost", "operator", "capability"] -> {:error, :reserved_sub}
      String.starts_with?(sub, "sites_token:") -> {:error, :reserved_sub}
      true -> :ok
    end
  end

  defp reject_reserved_sub(_), do: {:error, :reserved_sub}

  # A token that names an audience must name one we accept. `:audience`
  # is the client id IdentiKey puts in `aud` (`mjolnir-cli` for `mj`,
  # `mjolnir-term` for the browser). A configured audience requires the
  # claim. `:require_audience` false is the only way to accept an omission.
  defp audience_ok?(claims) do
    auth = Application.get_env(:mjolnir, :auth, [])

    audience_matches?(
      Map.get(claims, "aud"),
      Keyword.get(auth, :audience),
      audience_required?(auth)
    )
  end

  @doc false
  def audience_required?(auth) when is_list(auth) do
    case Keyword.fetch(auth, :require_audience) do
      {:ok, require?} -> require?
      :error -> audience_configured?(Keyword.get(auth, :audience))
    end
  end

  defp audience_configured?(value) when is_binary(value), do: value != ""

  defp audience_configured?(values) when is_list(values) do
    Enum.any?(values, fn
      value when is_binary(value) -> value != ""
      _ -> false
    end)
  end

  defp audience_configured?(_), do: false

  @doc false
  def audience_matches?(aud, expected, require? \\ false) do
    allowed =
      case expected do
        nil -> []
        value when is_binary(value) -> [value]
        values when is_list(values) -> Enum.filter(values, &is_binary/1)
        _ -> []
      end

    presented =
      case aud do
        nil -> []
        value when is_binary(value) -> [value]
        values when is_list(values) -> Enum.filter(values, &is_binary/1)
        _ -> :invalid
      end

    cond do
      presented == :invalid -> {:error, :audience}
      presented == [] and require? -> {:error, :audience}
      presented == [] -> :ok
      allowed == [] -> :ok
      Enum.any?(presented, &(&1 in allowed)) -> :ok
      true -> {:error, :audience}
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
