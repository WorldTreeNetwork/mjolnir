defmodule Mjolnir.Relay.RoomClassTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Relay.RoomClass

  @owner Mjolnir.Deploy.Owner.encode(:binary.copy(<<9>>, 32))

  test "protected and open shapes" do
    assert RoomClass.classify("t/#{@owner}/standup") == :protected
    assert RoomClass.classify("t/#{@owner}/~open/standup") == :open
    assert RoomClass.classify("t/#{@owner}/open") == :protected
    assert RoomClass.classify("t/#{@owner}/_open") == :protected
  end

  test "invalid corpus does not decode or trim" do
    padded = " " <> @owner
    noncanonical = "not-an-owner"

    for root <- [
          "t/#{@owner}",
          "t/#{@owner}/standup/extra",
          "t/#{@owner}/~open",
          "t/#{@owner}/~open/standup/extra",
          "t/#{@owner}//standup",
          "t/#{@owner}/.",
          "t/#{@owner}/..",
          "t/#{@owner}/%7Eopen/standup",
          "t/#{@owner}/%257Eopen/standup",
          "t/#{@owner}/~Open/standup",
          "t/#{@owner}/~~open/standup",
          "t/#{@owner}/stand up",
          "t/#{@owner}/~open/stand%2Fup",
          "t/#{padded}/standup",
          "t/#{noncanonical}/standup",
          "t/#{@owner}/~open/~open",
          ""
        ] do
      assert RoomClass.classify(root) == :invalid, root
    end

    assert RoomClass.classify(:not_a_root) == :invalid
    assert RoomClass.classify(nil) == :invalid
  end
end
