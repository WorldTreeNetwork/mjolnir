defmodule Mjolnir.API.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Mjolnir.API.Router

  @opts Router.init([])

  setup do
    original = Application.get_env(:mjolnir, :auth, [])
    Application.put_env(:mjolnir, :auth, bypass_localhost: true)
    on_exit(fn -> Application.put_env(:mjolnir, :auth, original) end)
    :ok
  end

  defp request(method, path, body \\ nil) do
    conn = conn(method, path, body && Jason.encode!(body))

    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  describe "GET /api/health" do
    test "returns 200 with status ok" do
      conn = request(:get, "/api/health")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
    end
  end

  describe "GET /api/vms" do
    test "returns 200 with empty VM list" do
      conn = request(:get, "/api/vms")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["vms"] == []
    end
  end

  describe "GET /api/vms/:id" do
    test "returns 404 for non-existent VM" do
      conn = request(:get, "/api/vms/nonexistent-id")
      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_found"
    end
  end

  describe "DELETE /api/vms/:id" do
    test "returns 404 for non-existent VM" do
      conn = request(:delete, "/api/vms/nonexistent-id")
      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_found"
    end
  end

  describe "GET /api/vms/:id/ticket" do
    test "returns 404 for non-existent VM" do
      conn = request(:get, "/api/vms/nonexistent-id/ticket")
      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_found"
    end
  end

  describe "GET /api/vms/:id/node-id" do
    test "returns 404 for non-existent VM" do
      conn = request(:get, "/api/vms/nonexistent-id/node-id")
      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_found"
    end
  end

  describe "unknown routes" do
    test "returns 404" do
      conn = request(:get, "/api/unknown")
      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_found"
    end
  end

  describe "GET /api/dormant" do
    test "returns empty list when no dormant VMs" do
      conn = request(:get, "/api/dormant")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["dormant"] == []
    end

    test "returns dormant VMs with correct shape" do
      vm_id = "test-dormant-#{:erlang.unique_integer([:positive])}"
      Mjolnir.DormantRegistry.register(vm_id, "snap-1", %{vcpus: 1})

      on_exit(fn -> Mjolnir.DormantRegistry.unregister(vm_id) end)

      conn = request(:get, "/api/dormant")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert [entry] = body["dormant"]
      assert entry["vm_id"] == vm_id
      assert entry["snapshot_name"] == "snap-1"
      assert entry["pending_messages"] == 0
      assert entry["state"] == "dormant"
      assert is_binary(entry["dormant_since"])
    end
  end

  describe "scope enforcement" do
    setup do
      Application.put_env(:mjolnir, :auth, bypass_localhost: false)
      :ok
    end

    test "returns 401 without token from non-localhost" do
      conn =
        conn(:get, "/api/vms")
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 401
    end
  end
end
