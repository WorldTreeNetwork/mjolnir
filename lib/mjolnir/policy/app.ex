defmodule Mjolnir.Policy.App do
  @moduledoc """
  Authorization policy for deployed apps (`Mjolnir.Deploy.Registry` entries).

  Mirrors `Mjolnir.Policy.VM`, including clause ordering, because the two are
  read side by side and a divergence between them is a bug waiting to happen:

  1. Localhost bypass (ops) — MUST be first
  2. Collection actions (`:deploy_new`, `:list`) — any authenticated user
  3. Resource actions — owner only
  4. Default deny

  ## Why this exists (mjolnir-xuv)

  `POST /api/deploy` and the `/api/apps/:app/domain` endpoints sat behind
  `require_scope` alone. A scope check proves *who is calling*, not *what they
  may touch* — so any authenticated caller could redeploy, or repoint the custom
  domain of, an app belonging to someone else. That is the exact surface that
  aims hostnames at VMs, so the blast radius was another tenant's live site.

  ## Legacy entries

  An entry written before ownership existed has `owner_id: nil`. Those are
  denied to regular users and allowed only to localhost — same as `Policy.VM`
  does for nil-owner VMs. Fail closed and back-fill the owner; do not relax the
  policy, or every legacy app stays permanently world-writable.
  """

  @type action ::
          :deploy_new
          | :list
          | :read
          | :deploy
          | :set_domain
          | :remove_domain
          | :issue_cert
          | :set_secrets
          | :unset_secrets
          | :adopt
  @type user :: %{user_id: String.t()} | nil
  @type resource :: %{owner_id: String.t() | nil} | nil

  @doc """
  Check if a user may perform an action on an app.

  `resource` is the app's registry entry (or nil for collection actions).
  Returns `:ok` or `:error`.
  """
  @spec authorize(action(), user(), resource()) :: :ok | :error

  # Localhost gets full access (ops) — MUST be first
  def authorize(_, %{user_id: "localhost"}, _), do: :ok

  # Deploying a NEW app and listing are collection actions: any authenticated
  # user. Ownership is stamped at creation, exactly as VM spawn does.
  def authorize(:deploy_new, %{user_id: uid}, _) when is_binary(uid), do: :ok
  def authorize(:list, %{user_id: uid}, _) when is_binary(uid), do: :ok

  # Legacy entries (nil owner_id) — deny to regular users
  def authorize(_, %{user_id: _}, %{owner_id: nil}), do: :error

  # Resource actions: owner only
  def authorize(action, %{user_id: uid}, %{owner_id: oid})
      when action in [
             :read,
             :deploy,
             :set_domain,
             :remove_domain,
             :issue_cert,
             :set_secrets,
             :unset_secrets,
             :adopt
           ] do
    if uid == oid, do: :ok, else: :error
  end

  # Default deny
  def authorize(_, _, _), do: :error

  @doc """
  Filter a list of app entries down to those the user may read.

  Localhost sees everything; a regular user sees only apps they own. Legacy
  nil-owner entries are hidden from regular users, consistent with `authorize/3`
  — otherwise `GET /api/apps` would leak every tenant's app names, URLs and
  custom domains.
  """
  @spec filter_readable([resource()], user()) :: [resource()]
  def filter_readable(entries, user) when is_list(entries) do
    Enum.filter(entries, &(authorize(:read, user, &1) == :ok))
  end
end
