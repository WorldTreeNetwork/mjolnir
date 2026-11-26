defmodule Mjolnir.VMRelayLocatorTest do
  use ExUnit.Case, async: false

  alias Mjolnir.VM
  alias Mjolnir.Vsock.Protocol

  test "late boot and disk resume send current relay locators to the guest" do
    id = "locator-#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), id)
    File.mkdir!(dir)

    on_exit(fn ->
      Mjolnir.StateStore.delete(id)
      File.rm_rf!(dir)
    end)

    env_path = Path.join(dir, "relay.env")
    locator_path = Path.join(dir, "locator.json")
    endpoint_id = String.duplicate("ab", 32)
    File.write!(env_path, "MJOLNIR_RELAY_ENABLED=true\nMJOLNIR_RELAY_HOST=relay.example\n")

    File.write!(
      locator_path,
      Jason.encode!(%{"host" => "relay.example", "endpoint_id" => endpoint_id})
    )

    configure(:relay_locator_env_path, env_path)
    configure(:relay_locator_path, locator_path)
    configure(:aie_device_path, Path.join(dir, "no-aie-device"))

    vsock_path = Path.join(dir, "v")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, vsock_path}])
    test_pid = self()
    spawn_link(fn -> serve_guest(listener, test_pid) end)

    state = %VM{
      id: id,
      late_boot: true,
      vsock_path: vsock_path,
      rootfs_path: dir,
      net_config: %{guest_ip: "10.200.1.2"},
      config: %{vcpu_count: 1, mem_size_mib: 512, base_image: "fixture"},
      restart_policy: :never
    }

    assert {:noreply, %{state: :running, vsock_conn: conn}} =
             VM.handle_info(:poll_late_boot, state)

    GenServer.stop(conn)

    assert_receive {:identity, %{"locators" => locators}}
    assert locators["relay_url"] == "https://relay.example/"
    assert locators["relay_iroh_endpoint_id"] == endpoint_id

    File.rm!(locator_path)
    File.mkdir!(locator_path)

    assert {:noreply, %{state: :running, vsock_conn: conn}} =
             VM.handle_info(:poll_late_boot, %{state | resume_mode: true})

    GenServer.stop(conn)

    assert_receive {:identity, %{"locators" => refreshed}}
    refute Map.has_key?(refreshed, "relay_url")
    refute Map.has_key?(refreshed, "relay_iroh_endpoint_id")
    assert refreshed["blob_door_url"] == locators["blob_door_url"]
  end

  defp configure(key, value) do
    previous = Application.fetch_env(:mjolnir, key)
    Application.put_env(:mjolnir, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:mjolnir, key, old)
        :error -> Application.delete_env(:mjolnir, key)
      end
    end)
  end

  defp serve_guest(listener, test_pid) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, "CONNECT 5000\n"} = :gen_tcp.recv(socket, 0, 2_000)
        :ok = :gen_tcp.send(socket, "OK 5000\n")

        case Protocol.read_json_response(socket, 2_000) do
          {:ok, request} ->
            response = reply(request, test_pid)
            :ok = :gen_tcp.send(socket, Protocol.encode(response))

          {:error, :closed} ->
            :ok
        end

        :gen_tcp.close(socket)
        serve_guest(listener, test_pid)

      {:error, :closed} ->
        :ok
    end
  end

  defp reply(%{"type" => "ping"}, _), do: %{"type" => "pong"}
  defp reply(%{"type" => "exec"}, _), do: %{"stdout" => "ROUTE=10.200.0.1\n"}
  defp reply(%{"type" => "configure_network"}, _), do: %{"exit_code" => 0}

  defp reply(%{"type" => "configure_iroh"}, _),
    do: %{"type" => "configure_iroh_response", "ok" => true}

  defp reply(%{"type" => "configure_identity"} = request, test_pid) do
    send(test_pid, {:identity, request})
    %{"exit_code" => 0}
  end
end
