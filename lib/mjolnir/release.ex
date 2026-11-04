defmodule Mjolnir.Release do
  @moduledoc """
  Identity of this compiled release.

  Deploy writes `priv/release_id` before `mix compile`. The id is baked into
  the beam. A running node keeps the previous id until `Mjolnir.Cutover`
  loads the new beam. Reading the file at request time would let the old
  node claim the new release.
  """

  id_path = Path.expand("../../priv/release_id", __DIR__)
  @external_resource id_path
  @id if(File.regular?(id_path), do: String.trim(File.read!(id_path)), else: "unreleased")

  @spec id() :: String.t()
  def id, do: @id
end
