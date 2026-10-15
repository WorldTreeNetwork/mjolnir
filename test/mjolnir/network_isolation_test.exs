defmodule Mjolnir.NetworkIsolationTest do
  use ExUnit.Case, async: true

  test "guest-to-guest drop is behind the sidecar accept" do
    [accept, drop] = Mjolnir.Network.guest_isolation_specs("10.200.0.0/10", "10.200.0.1")

    assert accept == ["-s", "10.192.0.0/10", "-d", "10.200.0.1/32", "-j", "ACCEPT"]
    assert drop == ["-s", "10.192.0.0/10", "-d", "10.192.0.0/10", "-j", "DROP"]
  end
end
