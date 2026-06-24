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

  @doc """
  Authorize an action on a durable StateStore *record* rather than a live VM.

  Used by operator endpoints (retire/revive) that act on stranded or `:failed`
  records, which have no live GenServer for `authorize_vm/4` to find. The
  `localhost` user bypasses ownership (same rule as the `/api/vms` list filter);
  any other user must own the record. On a missing record the callback still
  runs so the handler can return its own 404 (keeps behaviour uniform with
  `Mjolnir.VM.retire/revive` returning `{:error, :not_found}`).
  """
  def authorize_record(conn, vm_id, callback) do
    user_id = conn.assigns[:user_id]

    owner =
      case Mjolnir.StateStore.get(vm_id) do
        {:ok, record} -> Map.get(record.spawn_config || %{}, "owner_id")
        :not_found -> :no_record
      end

    cond do
      owner == :no_record ->
        callback.()

      user_id == "localhost" ->
        callback.()

      owner == user_id ->
        callback.()

      true ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "not_found"}))
        |> halt()
    end
  end
end
