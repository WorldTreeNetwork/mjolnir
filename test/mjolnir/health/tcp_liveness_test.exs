defmodule Mjolnir.Health.TcpLivenessTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Health.TcpLiveness

  # Minimal VM struct with just the fields the probe reads. `struct!` mirrors
  # the fixture style used in Mjolnir.Gateway.RoutesTest.
  defp vm(net_config), do: struct!(%Mjolnir.VM{id: "vm-test"}, net_config: net_config)

  defp live_vm, do: vm(%{tap_name: "tap0", guest_ip: "10.200.0.5", guest_mac: "aa:bb"})

  describe "probe/2 — liveness interpretation (independent of vsock)" do
    test "SYN-ACK (connect :ok) => :alive" do
      connect = fn _addr, _port, _timeout -> :ok end
      assert TcpLiveness.probe(live_vm(), ports: [3000], connect: connect) == :alive
    end

    test "RST (:econnrefused) still proves the guest kernel is up => :alive" do
      connect = fn _addr, _port, _timeout -> {:error, :econnrefused} end
      assert TcpLiveness.probe(live_vm(), ports: [3000], connect: connect) == :alive
    end

    test "timeout => :unreachable (this is the genuine-dead signal)" do
      connect = fn _addr, _port, _timeout -> {:error, :timeout} end
      assert TcpLiveness.probe(live_vm(), ports: [3000], connect: connect) == :unreachable
    end

    test "host/net unreachable => :unreachable" do
      for reason <- [:ehostunreach, :enetunreach, :ehostdown] do
        connect = fn _addr, _port, _timeout -> {:error, reason} end
        assert TcpLiveness.probe(live_vm(), ports: [3000], connect: connect) == :unreachable
      end
    end

    test "a local/unexpected error never manufactures a false :alive" do
      connect = fn _addr, _port, _timeout -> {:error, :emfile} end
      assert TcpLiveness.probe(live_vm(), ports: [3000], connect: connect) == :unreachable
    end

    test "alive if ANY candidate port answers (first refuses, second accepts)" do
      # 3000 refused-with-timeout, 8080 accepts.
      connect = fn _addr, port, _timeout ->
        if port == 8080, do: :ok, else: {:error, :timeout}
      end

      assert TcpLiveness.probe(live_vm(), ports: [3000, 8080], connect: connect) == :alive
    end

    test "unreachable only when ALL candidate ports fail" do
      connect = fn _addr, _port, _timeout -> {:error, :timeout} end
      assert TcpLiveness.probe(live_vm(), ports: [3000, 8080], connect: connect) == :unreachable
    end
  end

  describe "probe/2 — cannot corroborate" do
    test "no net_config => :unknown" do
      assert TcpLiveness.probe(vm(nil), connect: fn _, _, _ -> :ok end) == :unknown
    end

    test "blank guest_ip => :unknown" do
      v = vm(%{tap_name: "tap0", guest_ip: "", guest_mac: "aa:bb"})
      assert TcpLiveness.probe(v, connect: fn _, _, _ -> :ok end) == :unknown
    end

    test "empty explicit port list => :unknown (nothing to probe)" do
      assert TcpLiveness.probe(live_vm(), ports: [], connect: fn _, _, _ -> :ok end) == :unknown
    end
  end

  describe "probe/2 — address is passed to the connector" do
    test "a dotted IPv4 guest_ip is parsed to an inet tuple" do
      parent = self()

      connect = fn addr, _port, _timeout ->
        send(parent, {:addr, addr})
        :ok
      end

      TcpLiveness.probe(live_vm(), ports: [3000], connect: connect)
      assert_received {:addr, {10, 200, 0, 5}}
    end
  end
end
