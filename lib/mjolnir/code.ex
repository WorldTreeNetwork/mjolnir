defmodule Mjolnir.Code do
  @moduledoc """
  Compile-time revision of this beam.

  The value is the same `priv/release_id` that `Mjolnir.Release` bakes in.
  It lives on this module so a hot cutover has to load this beam before a
  running node reports the new revision. Loading only `Mjolnir.Release` and
  `Mjolnir.API.Router` leaves `revision/0` on the previous id.
  """

  id_path = Path.expand("../../priv/release_id", __DIR__)
  @external_resource id_path
  @revision if(File.regular?(id_path), do: String.trim(File.read!(id_path)), else: "unreleased")

  @spec revision() :: String.t()
  def revision, do: @revision
end
