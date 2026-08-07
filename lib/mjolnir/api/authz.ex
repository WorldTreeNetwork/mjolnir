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

      # Registered but unresponsive (wedged GenServer mailbox, mjolnir-8ie): the
      # VM exists, we just can't reach it — a 503, never a 404.
      {:error, :unreachable} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{error: "vm_unreachable"}))
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

  @doc """
  Authorize a resource-level action on a deployed app (mjolnir-xuv).

  Looks the app up in `Mjolnir.Deploy.Registry`, checks `Mjolnir.Policy.App`,
  and calls the callback with the entry. Denial returns **404, not 403** —
  matching `authorize_vm/4`, so a caller cannot enumerate other tenants' app
  names by distinguishing "exists but forbidden" from "does not exist".
  """
  def authorize_app(conn, app_name, action, callback) do
    user = %{user_id: conn.assigns[:user_id]}

    case Mjolnir.Deploy.Registry.get(app_name) do
      {:ok, entry} ->
        case Mjolnir.Policy.App.authorize(action, user, entry) do
          :ok ->
            callback.(entry)

          :error ->
            Logger.debug(
              "Authz denied: user=#{inspect(user.user_id)} action=#{action} app=#{app_name}"
            )

            app_not_found(conn, app_name)
        end

      {:error, :not_found} ->
        app_not_found(conn, app_name)
    end
  end

  @doc """
  Authorize `POST /api/deploy`, which both creates and updates.

  A first deploy is a collection action — any authenticated user, with ownership
  stamped at creation (the same shape as VM spawn). A REDEPLOY of an existing
  app is a resource action and requires ownership; without this, any
  authenticated caller could push code to, or cut over, someone else's app.

  The callback receives the existing entry, or `nil` for a first deploy.
  """
  def authorize_deploy(conn, app_name, callback) do
    user = %{user_id: conn.assigns[:user_id]}

    case Mjolnir.Deploy.Registry.get(app_name) do
      {:ok, entry} ->
        case Mjolnir.Policy.App.authorize(:deploy, user, entry) do
          :ok ->
            callback.(entry)

          :error ->
            Logger.debug(
              "Authz denied: user=#{inspect(user.user_id)} action=deploy app=#{app_name}"
            )

            app_not_found(conn, app_name)
        end

      {:error, :not_found} ->
        case Mjolnir.Policy.App.authorize(:deploy_new, user, nil) do
          :ok ->
            callback.(nil)

          :error ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(403, Jason.encode!(%{error: "forbidden"}))
            |> halt()
        end
    end
  end

  defp app_not_found(conn, app_name) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "app_not_found", app: app_name}))
    |> halt()
  end
end
