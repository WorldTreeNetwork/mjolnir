defmodule Mjolnir.API.TermPage do
  @moduledoc """
  The hosted browser terminal (mjolnir-wrug).

  A single HTML page: xterm.js talking to `GET /api/vms/:id/pty`. Browsers
  cannot set an Authorization header on `WebSocket`, so `GET /term/:id`
  stashes a JWT in the `mj_term` cookie and the PTY socket rides that.
  """

  @template_path Path.expand("../../../priv/term/index.html", __DIR__)
  @external_resource @template_path
  @template File.read!(@template_path)

  @cookie Mjolnir.API.Auth.term_cookie()

  @doc "Render the page with the VM id and tmux session baked in."
  @spec render(String.t(), String.t() | nil) :: String.t()
  def render(vm_id, session) when is_binary(vm_id) do
    session = session || "main"
    short = vm_short(vm_id)

    @template
    |> String.replace("{{VM_ID}}", vm_id)
    |> String.replace("{{VM_ID_JSON}}", Jason.encode!(vm_id))
    |> String.replace("{{VM_SHORT}}", short)
    |> String.replace("{{SESSION}}", session)
    |> String.replace("{{SESSION_JSON}}", Jason.encode!(session))
  end

  @doc """
  If the request carried `?token=`, stash it in the HttpOnly cookie and
  redirect to the same path without the token. Leaves other query params
  (notably `session`) intact.
  """
  @spec stash_token(Plug.Conn.t()) :: Plug.Conn.t()
  def stash_token(conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    case conn.query_params["token"] do
      token when is_binary(token) and token != "" ->
        rest = Map.delete(conn.query_params, "token")

        location =
          case URI.encode_query(rest) do
            "" -> conn.request_path
            q -> conn.request_path <> "?" <> q
          end

        conn
        |> Plug.Conn.put_resp_cookie(@cookie, token,
          http_only: true,
          secure: true,
          same_site: "Lax",
          path: "/",
          max_age: 12 * 60 * 60
        )
        |> Plug.Conn.put_resp_header("location", location)
        |> Plug.Conn.send_resp(302, "")
        |> Plug.Conn.halt()

      _ ->
        conn
    end
  end

  defp vm_short(id) do
    case String.split(id, "-", parts: 2) do
      [head, _] -> head
      _ -> String.slice(id, 0, 8)
    end
  end
end
