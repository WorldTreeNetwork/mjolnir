defmodule Mjolnir.Deploy.Owner do
  @moduledoc """
  Who a deploy is stamped as.

  A loopback deploy with no credential authenticates as `localhost`. That
  hides the app from the owner's `mj list`. The host may name the real
  owner with `X-Owner-Id` (64 lowercase hex). Any other caller is stamped
  as themselves; the header does not let them impersonate.
  """

  @owner ~r/^[0-9a-f]{64}$/

  @spec resolve(String.t() | nil, String.t() | nil) :: String.t() | nil
  def resolve("localhost", header) when is_binary(header) do
    owner = String.trim(header)
    if Regex.match?(@owner, owner), do: owner, else: "localhost"
  end

  def resolve(user_id, _), do: user_id
end
