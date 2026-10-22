defmodule Mjolnir.API.AuthzVmTest do
  # PTY denial is 403. Every other VM action still hides denial as 404.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Mjolnir.API.Authz

  defmodule OwnedVM do
    use GenServer

    def start_link(vm_id) do
      GenServer.start_link(__MODULE__, vm_id, name: {:via, Registry, {Mjolnir.VMRegistry, vm_id}})
    end

    @impl true
    def init(vm_id), do: {:ok, %{id: vm_id, owner_id: "alice"}}

    @impl true
    def handle_call(:get_state, _from, state), do: {:reply, state, state}
  end

  setup do
    vm_id = "authz-#{System.unique_integer([:positive])}"
    {:ok, _pid} = OwnedVM.start_link(vm_id)
    %{vm_id: vm_id}
  end

  defp conn_as(user_id) do
    conn(:get, "/pty")
    |> assign(:user_id, user_id)
    |> assign(:claims, %{"scope" => "pty:connect"})
  end

  test "a stranger opening the PTY gets 403, not a pretend 404", %{vm_id: vm_id} do
    conn =
      Authz.authorize_vm(conn_as("mallory"), vm_id, :pty, fn _vm ->
        raise "must not attach"
      end)

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"] == "forbidden"
    assert conn.halted
  end

  test "a stranger reading the VM is still a 404", %{vm_id: vm_id} do
    conn =
      Authz.authorize_vm(conn_as("mallory"), vm_id, :read, fn _vm ->
        raise "must not read"
      end)

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"] == "not_found"
  end

  test "a missing VM stays 404 even for a PTY", %{vm_id: _vm_id} do
    conn =
      Authz.authorize_vm(conn_as("mallory"), "no-such-vm", :pty, fn _vm ->
        raise "must not attach"
      end)

    assert conn.status == 404
  end
end
