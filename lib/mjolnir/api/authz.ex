defmodule Mjolnir.API.Authz do
  @moduledoc """
  Authorization helpers for scope-based access control.
  """

  import Plug.Conn

  @doc """
  Check that the authenticated user has the required scope.

  Parses the space-separated `scope` claim from JWT claims.
  Sends 403 and halts if the scope is missing.
  """
  def require_scope(conn, required_scope) do
    scopes =
      conn.assigns[:claims]
      |> Map.get("scope", "")
      |> String.split(" ", trim: true)

    if required_scope in scopes do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{error: "insufficient_scope", required: required_scope}))
      |> halt()
    end
  end
end
