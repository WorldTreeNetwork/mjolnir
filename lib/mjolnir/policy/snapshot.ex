defmodule Mjolnir.Policy.Snapshot do
  @moduledoc """
  Authorization policy for snapshot resources.

  Same clause ordering as VM policy: localhost first, then action-specific,
  then default deny.
  """

  @type action :: :list | :read | :create | :delete
  @type user :: %{user_id: String.t()} | nil
  @type resource :: %{atom() => any()} | nil

  @doc """
  Check if a user is authorized to perform an action on a snapshot.

  Returns `:ok` or `:error`.

  Snapshot metadata uses atom keys (normalized at the JSON decode boundary).
  """
  @spec authorize(action(), user(), resource()) :: :ok | :error

  # Localhost gets full access (ops) — MUST be first
  def authorize(_, %{user_id: "localhost"}, _), do: :ok

  # List: any authenticated user (results are filtered by caller)
  def authorize(:list, %{user_id: uid}, _) when is_binary(uid), do: :ok

  # Create: any authenticated user (ownership stamped at creation)
  def authorize(:create, %{user_id: uid}, _) when is_binary(uid), do: :ok

  # Legacy snapshots (nil owner_id) — deny to regular users
  def authorize(_, %{user_id: _}, %{owner_id: nil}), do: :error

  # Resource actions: owner only
  def authorize(action, %{user_id: uid}, %{owner_id: oid})
      when action in [:read, :delete] do
    if uid == oid, do: :ok, else: :error
  end

  # Default deny
  def authorize(_, _, _), do: :error
end
