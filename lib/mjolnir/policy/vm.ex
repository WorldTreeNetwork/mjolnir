defmodule Mjolnir.Policy.VM do
  @moduledoc """
  Authorization policy for VM resources.

  Uses pattern matching on `authorize(action, user, resource)` to enforce
  ownership-based access control. Clause ordering is critical:

  1. Localhost bypass (ops) — MUST be first
  2. Collection actions (spawn, list) — any authenticated user
  3. Resource actions — owner only
  4. Default deny
  """

  @type action :: :spawn | :list | :read | :exec | :stop | :snapshot | :ticket | :pty | :message
  @type user :: %{user_id: String.t()} | nil
  @type resource :: %{owner_id: String.t() | nil} | nil

  @doc """
  Check if a user is authorized to perform an action on a VM resource.

  Returns `:ok` or `:error`.
  """
  @spec authorize(action(), user(), resource()) :: :ok | :error

  # Localhost gets full access (ops) — MUST be first
  def authorize(_, %{user_id: "localhost"}, _), do: :ok

  # Spawn/list: any authenticated user
  def authorize(:spawn, %{user_id: uid}, _) when is_binary(uid), do: :ok
  def authorize(:list, %{user_id: uid}, _) when is_binary(uid), do: :ok

  # Legacy VMs (nil owner_id) — deny to regular users
  def authorize(_, %{user_id: _}, %{owner_id: nil}), do: :error

  # Resource actions: owner only
  def authorize(action, %{user_id: uid}, %{owner_id: oid})
      when action in [:read, :exec, :stop, :snapshot, :ticket, :pty, :message] do
    if uid == oid, do: :ok, else: :error
  end

  # Default deny
  def authorize(_, _, _), do: :error
end
