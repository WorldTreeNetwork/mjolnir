defmodule Mjolnir.NetworkTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Network

  describe "allocate_ip/1" do
    test "allocates IP within configured range (10.192-255.x.x)" do
      ip = Network.allocate_ip("test-vm-123")
      [o1, o2, _o3, _o4] = ip |> String.split(".") |> Enum.map(&String.to_integer/1)

      assert o1 == 10
      assert o2 >= 192 and o2 <= 255
    end

    test "generates consistent IP for same VM ID" do
      ip1 = Network.allocate_ip("test-vm")
      ip2 = Network.allocate_ip("test-vm")
      assert ip1 == ip2
    end

    test "different VM IDs get different IPs" do
      ip1 = Network.allocate_ip("vm-a")
      ip2 = Network.allocate_ip("vm-b")
      assert ip1 != ip2
    end

    test "avoids .0 and .255 in last octet" do
      # Generate many IPs and check none end in .0 or .255
      ips =
        1..1000
        |> Enum.map(&"vm-#{&1}")
        |> Enum.map(&Network.allocate_ip/1)

      for ip <- ips do
        last_octet = ip |> String.split(".") |> List.last() |> String.to_integer()
        refute last_octet == 0, "IP #{ip} ends in .0"
        refute last_octet == 255, "IP #{ip} ends in .255"
      end
    end
  end

  describe "generate_mac/1" do
    test "generates valid locally-administered MAC" do
      mac = Network.generate_mac("test-vm")
      # Format: 02:FC:00:xx:xx:xx
      assert mac =~ ~r/^02:FC:00:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}$/i
    end

    test "generates consistent MAC for same VM ID" do
      mac1 = Network.generate_mac("test-vm")
      mac2 = Network.generate_mac("test-vm")
      assert mac1 == mac2
    end

    test "different VM IDs get different MACs" do
      mac1 = Network.generate_mac("vm-a")
      mac2 = Network.generate_mac("vm-b")
      assert mac1 != mac2
    end

    test "MAC prefix is locally administered" do
      mac = Network.generate_mac("any-vm")
      [first_byte | _] = String.split(mac, ":")
      # 02 in hex = 0000 0010 in binary
      # Bit 0 (LSB) = 0 means unicast
      # Bit 1 = 1 means locally administered
      assert first_byte == "02"
    end
  end

  describe "tap_name/1" do
    test "generates tap name with the configured prefix" do
      name = Network.tap_name("abc12345-6789-abcd-ef01")
      assert name == "#{Network.tap_prefix()}abc12345"
    end

    test "truncates to 8 chars of VM ID" do
      name = Network.tap_name("12345678901234567890")
      assert name == "#{Network.tap_prefix()}12345678"
    end

    test "test-env interfaces are unmistakable for production ones, and vice versa" do
      # Not cosmetic. TAP devices are host-global, and Cleanup deletes any DOWN
      # interface matching its own prefix by SUBSTRING. If either prefix were a
      # substring of the other, a test BEAM sharing a host with production
      # would delete a live VM's TAP and cut its networking (mjolnir-0ut).
      # "mjt-" does not contain "mj-" — there is no consecutive "j-" — so the
      # two sweeps are blind to each other. This test exists so that a future
      # rename to, say, "mj-test-" fails here instead of in production.
      test_prefix = Network.tap_prefix()
      prod_prefix = "mj-"

      assert test_prefix != prod_prefix,
             "test config must not share production's TAP prefix (#{prod_prefix})"

      refute String.contains?(Network.tap_name("abc12345"), prod_prefix),
             "a test TAP name must not contain the production prefix, or production's " <>
               "Cleanup sweep would reap it"

      refute String.contains?("#{prod_prefix}abc12345", test_prefix),
             "a production TAP name must not contain the test prefix, or a test BEAM's " <>
               "Cleanup sweep would reap a live production VM's interface"
    end
  end

  describe "network_range/0" do
    test "returns default range" do
      assert Network.network_range() == "10.200.0.0/10"
    end
  end
end
