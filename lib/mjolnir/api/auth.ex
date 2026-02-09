defmodule Mjolnir.API.Auth do
  @moduledoc """
  Authentication plug for the Mjolnir HTTP API.

  Extracts and verifies JWT bearer tokens. Skips auth for health
  endpoints and for localhost requests when `bypass_localhost: true`.
  """

  import Plug.Conn
  @behaviour Plug

  @skip_auth_paths ["/api/health"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      conn.request_path in @skip_auth_paths ->
        conn

      localhost_bypass?(conn) ->
        assign(conn, :claims, %{"scope" => "vms:spawn vms:read vms:exec vms:stop shell:connect"})

      true ->
        verify_token(conn)
    end
  end

  defp localhost_bypass?(conn) do
    auth_config = Application.get_env(:mjolnir, :auth, [])

    Keyword.get(auth_config, :bypass_localhost, false) &&
      conn.remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]
  end

  defp verify_token(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- Mjolnir.Auth.Token.verify_token(token) do
      assign(conn, :claims, claims)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "invalid_token"}))
        |> halt()
    end
  end
end
