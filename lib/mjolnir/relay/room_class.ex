defmodule Mjolnir.Relay.RoomClass do
  @moduledoc """
  Classifies a verified room-token root. Literal slash, exact arity,
  canonical 32-byte base58 owner, room alphabet. No decoding.

  The relay verifier is not this module. Downstream code calls `classify/1`
  on the root `assess` already returned.
  """

  @room ~r/\A[A-Za-z0-9_-]{1,64}\z/

  @type class :: :open | :protected | :invalid

  @spec classify(term()) :: class()
  def classify(root) when is_binary(root) do
    case String.split(root, "/") do
      ["t", owner, room] ->
        if canonical_owner?(owner) and room?(room), do: :protected, else: :invalid

      ["t", owner, "~open", room] ->
        if canonical_owner?(owner) and room?(room), do: :open, else: :invalid

      _ ->
        :invalid
    end
  end

  def classify(_), do: :invalid

  defp room?(segment), do: Regex.match?(@room, segment)

  # `Owner.parse/1` trims. This classifier does not.
  defp canonical_owner?(owner) do
    owner == String.trim(owner) and match?({:ok, _}, Mjolnir.Deploy.Owner.parse(owner))
  end
end
