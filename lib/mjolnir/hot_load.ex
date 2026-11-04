defmodule Mjolnir.HotLoad do
  @moduledoc """
  Compile-time stamp of this beam.

  Same `priv/release_id` as `Mjolnir.Release` and `Mjolnir.Code`. A running
  node that already called `stamp/0` keeps the old value until cutover loads
  this beam. Reading the file at call time would report the new id without a
  load.
  """

  id_path = Path.expand("../../priv/release_id", __DIR__)
  @external_resource id_path
  @stamp if(File.regular?(id_path), do: String.trim(File.read!(id_path)), else: "unreleased")

  @spec stamp() :: String.t()
  def stamp, do: @stamp
end
