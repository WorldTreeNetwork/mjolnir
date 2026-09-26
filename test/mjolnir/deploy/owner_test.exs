defmodule Mjolnir.Deploy.OwnerTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Deploy.Owner

  @duke "27060fd66283eb5c6c900bce5b364fa512fb4c718b6af18acc7720c424e08821"

  test "localhost may stamp a 64-hex owner" do
    assert Owner.resolve("localhost", @duke) == @duke
    assert Owner.resolve("localhost", "  #{@duke}  ") == @duke
  end

  test "localhost keeps itself when the header is missing or not an owner id" do
    assert Owner.resolve("localhost", nil) == "localhost"
    assert Owner.resolve("localhost", "localhost") == "localhost"
    assert Owner.resolve("localhost", "not-an-owner") == "localhost"
  end

  test "a signed-in user cannot impersonate via the header" do
    assert Owner.resolve(@duke, "a" <> String.duplicate("b", 63)) == @duke
  end
end
