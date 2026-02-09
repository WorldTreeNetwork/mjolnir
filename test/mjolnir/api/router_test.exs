defmodule Mjolnir.API.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Mjolnir.API.Router

  @opts Router.init([])

  describe "GET /api/health" do
    test "returns 200 with ok status" do
      conn = conn(:get, "/api/health") |> Router.call(@opts)

      assert conn.status == 200
      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)
    end
  end

  describe "GET /api/vms" do
    test "returns empty list when no VMs running" do
      conn = conn(:get, "/api/vms") |> Router.call(@opts)

      assert conn.status == 200
      assert %{"vms" => []} = Jason.decode!(conn.resp_body)
    end
  end

  describe "GET /api/vms/:id" do
    test "returns 404 for non-existent VM" do
      conn = conn(:get, "/api/vms/nonexistent-id") |> Router.call(@opts)

      assert conn.status == 404
      assert %{"error" => "not_found"} = Jason.decode!(conn.resp_body)
    end
  end

  describe "POST /api/vms/:id/exec" do
    test "returns 400 when command is missing" do
      conn =
        conn(:post, "/api/vms/some-id/exec", %{})
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
      assert %{"error" => "command is required"} = Jason.decode!(conn.resp_body)
    end

    test "returns 400 when command is empty string" do
      conn =
        conn(:post, "/api/vms/some-id/exec", %{"command" => ""})
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
      assert %{"error" => "command is required"} = Jason.decode!(conn.resp_body)
    end

    test "returns 404 for non-existent VM" do
      conn =
        conn(:post, "/api/vms/nonexistent-id/exec", %{"command" => "uname"})
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 404
      assert %{"error" => "not_found"} = Jason.decode!(conn.resp_body)
    end
  end

  describe "DELETE /api/vms/:id" do
    test "returns 404 for non-existent VM" do
      conn = conn(:delete, "/api/vms/nonexistent-id") |> Router.call(@opts)

      assert conn.status == 404
      assert %{"error" => "not_found"} = Jason.decode!(conn.resp_body)
    end
  end

  describe "unknown routes" do
    test "returns 404 for unknown path" do
      conn = conn(:get, "/api/unknown") |> Router.call(@opts)

      assert conn.status == 404
      assert %{"error" => "not_found"} = Jason.decode!(conn.resp_body)
    end
  end

  describe "response content type" do
    test "all responses have application/json content type" do
      conn = conn(:get, "/api/health") |> Router.call(@opts)

      assert {"content-type", "application/json; charset=utf-8"} in conn.resp_headers
    end
  end
end
