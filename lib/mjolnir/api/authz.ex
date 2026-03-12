defmodule Mjolnir.API.Authz do
  @moduledoc """
  Authorization helpers for scope-based access control.
  """

  import Plug.Conn
  require Logger

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

  @doc """
  Authorize a resource-level action on a VM.

  Looks up the VM by id, checks policy, and calls the success callback with
  the VM state map. Returns 404 if not found, 403 if unauthorized.
  """
  def authorize_vm(conn, vm_id, action, callback) do
    user = %{user_id: conn.assigns[:user_id]}

    case Mjolnir.VM.get(vm_id) do
      {:ok, vm} ->
        case Mjolnir.Policy.VM.authorize(action, user, vm) do
          :ok ->
            callback.(vm)

          :error ->
            Logger.debug(
              "Authz denied: user=#{inspect(user.user_id)} action=#{action} vm=#{vm_id}"
            )

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(404, Jason.encode!(%{error: "not_found"}))
            |> halt()
        end

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "not_found"}))
        |> halt()
    end
  end
end
