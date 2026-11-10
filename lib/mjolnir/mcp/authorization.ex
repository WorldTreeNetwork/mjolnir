defmodule Mjolnir.MCP.Authorization do
  @moduledoc false

  @scopes %{
    "spawn_vm" => "vms:spawn",
    "list_vms" => "vms:read",
    "get_vm" => "vms:read",
    "exec" => "vms:exec",
    "stop_vm" => "vms:stop",
    "create_snapshot" => "snapshots:create",
    "list_snapshots" => "snapshots:read",
    "get_snapshot" => "snapshots:read",
    "delete_snapshot" => "snapshots:delete",
    "deliver_message" => "vms:exec",
    "get_connection_ticket" => "pty:connect",
    "list_dormant" => "vms:read",
    "await_pty" => "pty:connect"
  }
  @vm_actions %{
    "get_vm" => :read,
    "exec" => :exec,
    "stop_vm" => :stop,
    "create_snapshot" => :snapshot,
    "deliver_message" => :message,
    "get_connection_ticket" => :ticket,
    "await_pty" => :pty
  }
  @session_methods ~w(initialize notifications/initialized notifications/cancelled ping tools/list resources/list resources/templates/list resources/subscribe resources/unsubscribe prompts/list prompts/get completion/complete logging/setLevel notifications/roots/list_changed)
  @resources %{
    "mjolnir://vms" => "vms:read",
    "mjolnir://dormant" => "vms:read",
    "mjolnir://snapshots" => "snapshots:read"
  }

  # Only authenticated identity and scope strings cross into session state.
  # Never retain a connection, bearer token, cookie, or raw JWT claims.
  def context(conn) do
    %{
      user_id: conn.assigns[:user_id],
      kind: conn.assigns[:principal_kind],
      scope: get_in(conn.assigns, [:claims, "scope"]) || ""
    }
  end

  def control_principal?(%{kind: :operator, user_id: "localhost"}), do: true

  def control_principal?(%{kind: :user, user_id: uid}) when is_binary(uid) do
    uid != "" and uid != "localhost" and uid != "capability" and
      not String.starts_with?(uid, "sites_token:")
  end

  def control_principal?(_), do: false

  def request_allowed?(context, request) do
    control_principal?(context) and Enum.any?(Map.values(@scopes), &has_scope?(context, &1)) and
      request_scope_allowed?(context, request)
  end

  defp request_scope_allowed?(context, requests) when is_list(requests),
    do: Enum.all?(requests, &request_scope_allowed?(context, &1))

  defp request_scope_allowed?(context, %{"method" => "tools/call", "params" => %{"name" => name}}),
       do: has_scope?(context, @scopes[name])

  defp request_scope_allowed?(_context, %{"method" => "tools/call"}), do: false

  defp request_scope_allowed?(context, %{
         "method" => "resources/read",
         "params" => %{"uri" => uri}
       }),
       do: has_scope?(context, @resources[uri])

  defp request_scope_allowed?(_context, %{"method" => "resources/read"}), do: false
  defp request_scope_allowed?(_context, %{"method" => method}), do: method in @session_methods
  defp request_scope_allowed?(_context, _request), do: true

  def authorize_tool(context, name, args) do
    cond do
      not control_principal?(context) or not has_scope?(context, @scopes[name]) ->
        {:error, "Insufficient scope"}

      Map.has_key?(@vm_actions, name) ->
        authorize_vm(context, Map.get(args, "vm_id"), @vm_actions[name])

      name in ["get_snapshot", "delete_snapshot"] ->
        authorize_snapshot(
          context,
          Map.get(args, "name"),
          if(name == "get_snapshot", do: :read, else: :delete)
        )

      name == "spawn_vm" ->
        policy_result(Mjolnir.Policy.VM.authorize(:spawn, %{user_id: context.user_id}, nil))

      true ->
        :ok
    end
  end

  def authorize_resource(context, uri) do
    if control_principal?(context) and has_scope?(context, @resources[uri]),
      do: :ok,
      else: {:error, "Insufficient scope"}
  end

  def visible?(context, entry) do
    uid = context[:user_id]
    owner = Map.get(entry, :owner_id) || Map.get(entry, "owner_id")

    control_principal?(context) and
      (uid == "localhost" or
         (is_binary(uid) and Mjolnir.Deploy.Owner.same?(owner, uid)))
  end

  defp authorize_vm(context, id, action) when is_binary(id) do
    with {:ok, _} <- Mjolnir.API.Validation.validate_safe_name(id, "VM id") do
      case Mjolnir.VM.get(id) do
        {:ok, vm} ->
          policy_result(Mjolnir.Policy.VM.authorize(action, %{user_id: context.user_id}, vm))

        {:error, :unreachable} ->
          unavailable_vm(context, id, action)

        _ ->
          {:error, "Not found"}
      end
    else
      _ -> {:error, "Not found"}
    end
  end

  # A stalled VM is not a missing VM. Preserve that distinction for its
  # owner/operator without disclosing another owner's durable record.
  defp unavailable_vm(context, id, action) do
    owner =
      case Mjolnir.StateStore.get(id) do
        {:ok, record} -> Map.get(record.spawn_config || %{}, "owner_id")
        _ -> nil
      end

    case Mjolnir.Policy.VM.authorize(action, %{user_id: context.user_id}, %{owner_id: owner}) do
      :ok -> {:error, "VM unavailable"}
      _ -> {:error, "Not found"}
    end
  end

  defp authorize_vm(_, _, _), do: {:error, "Not found"}

  defp authorize_snapshot(context, name, action) when is_binary(name) do
    with {:ok, _} <- Mjolnir.API.Validation.validate_safe_name(name, "snapshot name"),
         {:ok, %{metadata: metadata}} <- Mjolnir.BTRFS.get_snapshot(name),
         :ok <- Mjolnir.Policy.Snapshot.authorize(action, %{user_id: context.user_id}, metadata) do
      :ok
    else
      _ -> {:error, "Not found"}
    end
  end

  defp authorize_snapshot(_, _, _), do: {:error, "Not found"}

  defp has_scope?(%{scope: scope}, required) when is_binary(scope) and is_binary(required),
    do: required in String.split(scope, " ", trim: true)

  defp has_scope?(_, _), do: false
  defp policy_result(:ok), do: :ok
  defp policy_result(_), do: {:error, "Not found"}
end
