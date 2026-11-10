defmodule Mjolnir.LiveAttachTest do
  use ExUnit.Case, async: false
  alias Mjolnir.{VM, Network}

  test "live attachment restores controls and metadata through read-only operations" do
    parent = self()

    connection =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(connection, :stop) end)
    node = String.duplicate("a1", 32)

    state = %VM{
      id: "adopt-existing",
      enable_iroh: true,
      vsock_path: "/existing/vsock",
      owner_id: "alice",
      secrets_mode: :managed,
      config: %{existing: true}
    }

    net = %{tap_name: "mjt-adopt", guest_ip: "10.200.1.2", guest_mac: "02:fc:00:01:02:03"}

    result =
      VM.attach_control_state(state,
        network: fn id ->
          send(parent, {:read_route, id})
          {:ok, net}
        end,
        iroh: fn path ->
          send(parent, {:read_identity, path})
          {:ok, %{ready: true, node_id: node, ticket: "existing-ticket"}}
        end,
        connect: fn id, path ->
          send(parent, {:connect_existing, id, path})
          {:ok, connection}
        end
      )

    assert_receive {:read_route, "adopt-existing"}
    assert_receive {:read_identity, "/existing/vsock"}
    assert_receive {:connect_existing, "adopt-existing", "/existing/vsock"}
    assert result.state == :running
    assert result.vsock_conn == connection
    assert is_reference(result.vsock_conn_ref)
    assert result.net_config == net
    assert result.iroh_node_id == node
    assert result.iroh_json == "existing-ticket"
    assert result.pty_ready
    assert String.ends_with?(result.rootfs_path, "/@vms/adopt-existing")
    assert result.config == state.config
    assert result.owner_id == "alice"
    assert result.secrets_mode == :managed
    assert result.hypervisor_port == nil
  end

  test "attachment failure preserves the live guest and skips disabled Iroh" do
    state = %VM{id: "adopt-offline", enable_iroh: false, vsock_path: "/existing/vsock"}

    result =
      VM.attach_control_state(state,
        network: fn _ -> {:error, :missing} end,
        iroh: fn _ -> raise "must not configure or query disabled Iroh" end,
        connect: fn _, _ -> {:error, :econnrefused} end
      )

    assert result.state == :running
    assert result.vsock_conn == nil
    assert result.hypervisor_port == nil
  end

  test "TAP recovery retains the kernel route instead of allocating a new address" do
    {:ok, net} = Network.recover_tap("existing-id", [%{"dst" => "10.201.2.3/32"}])
    assert net.guest_ip == "10.201.2.3"
    assert net.tap_name == Network.tap_name("existing-id")

    assert {:error, _} =
             Network.recover_tap("existing-id", [
               %{"dst" => "10.201.2.3"},
               %{"dst" => "10.201.2.4"}
             ])

    assert {:error, _} = Network.recover_tap("existing-id", [%{"dst" => "0.0.0.0/0"}])
    assert {:error, _} = Network.recover_tap("existing-id", [%{"dst" => "10.200.0.1"}])
  end
end
