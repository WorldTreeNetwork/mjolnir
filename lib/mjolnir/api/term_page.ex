defmodule Mjolnir.API.TermPage do
  @moduledoc """
  The hosted browser terminal (mjolnir-wrug).

  A single HTML page: xterm.js talking to `GET /api/vms/:id/pty`. Browsers
  cannot set an Authorization header on `WebSocket`, so `GET /term/:id`
  stashes a JWT in the `mj_term` cookie and the PTY socket rides that.
  """

  @template_path Path.expand("../../../priv/term/index.html", __DIR__)
  @mark_path Path.expand("../../../priv/term/identikey-mark.svg", __DIR__)
  @external_resource @template_path
  @external_resource @mark_path
  @template File.read!(@template_path)
  @mark File.read!(@mark_path)

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
    |> String.replace("{{IDENTIKEY_MARK}}", @mark)
  end

  @doc """
  Page shown when IdentiKey accepted the passkey and this VM still refused it.

  Login is not ownership. The owner and `pty_invites` are the only principals
  who see the terminal.
  """
  @spec denied() :: String.t()
  def denied do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Mjolnir</title>
      <style>
        html, body {
          margin: 0; height: 100%; background: #0b0c0b; color: #d7d4c8;
          font: 13px/1.45 "IBM Plex Mono", ui-monospace, Menlo, monospace;
        }
        main { max-width: 36rem; padding: 18vh 1.5rem 0; }
        a { color: #c4a35a; }
        #identikey {
          position: fixed; top: 16px; right: 18px; width: 42px; height: 37px;
        }
        #identikey svg { width: 100%; height: 100%; display: block; }
      </style>
    </head>
    <body>
      <div id="identikey" aria-label="IdentiKey">#{@mark}</div>
      <main>
        <p>IdentiKey signed you in. This terminal is locked to its owner.</p>
        <p><a href="/auth/logout">Log out</a></p>
      </main>
    </body>
    </html>
    """
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
