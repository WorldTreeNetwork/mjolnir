defmodule Mjolnir.Health.GuestNetworkTest do
  use ExUnit.Case, async: true
  alias Mjolnir.Health.GuestNetwork

  @pin "ROUTE 10.200.0.1 dev eth0 scope link\nDNS 127.0.0.1\nOK\n"

  test "intact isolated host pin is healthy, including explicit /32 spelling" do
    assert GuestNetwork.classify(:proxy, @pin) == :ok

    assert GuestNetwork.classify(:proxy, String.replace(@pin, "10.200.0.1 ", "10.200.0.1/32 ")) ==
             :ok
  end

  test "drift is not ok and therefore remains eligible for the level 2 heal" do
    assert GuestNetwork.level() == 2

    assert GuestNetwork.classify(:proxy, "ROUTE default dev eth0\n" <> @pin) ==
             {:dead, :proxy_default_route}

    assert GuestNetwork.classify(:proxy, "DNS 1.1.1.1\n" <> @pin) ==
             {:dead, :proxy_resolver_drift}

    assert GuestNetwork.classify(:proxy, "DNS 127.0.0.1\nOK") ==
             {:dead, :proxy_host_route_missing}

    assert GuestNetwork.classify(:proxy, String.replace(@pin, "127.0.0.1", "8.8.8.8")) ==
             {:dead, :proxy_resolver_drift}

    assert GuestNetwork.classify(:proxy, String.replace(@pin, "DNS 127.0.0.1\n", "")) ==
             {:dead, :proxy_resolver_drift}
  end

  test "host route matches an exact address and prefix" do
    for wrong <- ["10.200.0.10", "10.200.0.1/24", "110.200.0.1"] do
      assert GuestNetwork.classify(:proxy, String.replace(@pin, "10.200.0.1", wrong)) ==
               {:dead, :proxy_host_route_missing}
    end
  end

  test "connect failure, missing tools, and failed inspection never report healthy" do
    assert GuestNetwork.classify(:proxy, String.replace(@pin, "OK", "NOTOOL")) ==
             {:degraded, :no_egress_probe_tool}

    assert GuestNetwork.classify(:proxy, String.replace(@pin, "OK", "NOEGRESS")) ==
             {:dead, :egress_blocked}

    assert GuestNetwork.classify(:proxy, "INSPECTFAIL\n" <> @pin) ==
             {:dead, :network_inspection_failed}

    refute GuestNetwork.classify(:proxy, "") == :ok
  end

  test "ordinary guests keep the public probe and NOROUTE remains dead" do
    assert GuestNetwork.classify(:ordinary, "OK\n") == :ok
    assert GuestNetwork.classify(:ordinary, "NOROUTE\n") == {:dead, :no_default_route}
    assert GuestNetwork.classify(:ordinary, "NOEGRESS") == {:dead, :egress_blocked}
    assert GuestNetwork.classify(:ordinary, "NOTOOL") == {:degraded, :no_egress_probe_tool}
    assert GuestNetwork.command(:ordinary) =~ "http://1.1.1.1/"
    assert GuestNetwork.command(:proxy) =~ "command -v bash"

    assert GuestNetwork.command(:proxy) =~
             "timeout 3 bash -c 'exec 3<>/dev/tcp/10.200.0.1/4000'"

    refute GuestNetwork.command(:proxy) =~ "python3"
    refute GuestNetwork.command(:proxy) =~ "1.1.1.1"
  end
end
