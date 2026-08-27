defmodule Mjolnir.API.AuthzAppTest do
  # Enforcement-level coverage for mjolnir-xuv.
  #
  # policy/app_test.exs proves the POLICY decides correctly, and
  # policy/coverage_test.exs only greps the router source for a pattern — neither
  # proves the router actually WIRES the check to a response. The router tests
  # can't: they all set remote_ip to 127.0.0.1 and so run as "localhost", which
  # bypasses ownership entirely. These tests drive Authz directly with a
  # non-localhost user against a real Registry.
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Mjolnir.API.Authz

  setup do
    app = "authz-app-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Mjolnir.Deploy.Registry.put(app, %{
        release_snapshot: "rel-1",
        service_vm_id: "svc-1",
        url: "https://x",
        port: 3000,
        owner_id: "alice"
      })

    on_exit(fn -> Mjolnir.Deploy.Registry.delete(app) end)
    %{app: app}
  end

  defp conn_as(user_id) do
    conn(:put, "/whatever")
    |> assign(:user_id, user_id)
  end

  defp called?(fun), do: Process.get(fun, false)

  describe "authorize_app/4" do
    test "runs the callback for the owner", %{app: app} do
      conn =
        Authz.authorize_app(conn_as("alice"), app, :set_domain, fn entry ->
          Process.put(:cb, true)
          assert entry.owner_id == "alice"
          send_resp(conn_as("alice"), 200, "ok")
        end)

      assert called?(:cb)
      assert conn.status == 200
    end

    test "denies a non-owner with 404 and never runs the callback", %{app: app} do
      conn =
        Authz.authorize_app(conn_as("mallory"), app, :set_secrets, fn _e ->
          Process.put(:cb2, true)
          raise "callback must not run for a non-owner"
        end)

      refute called?(:cb2)
      assert conn.status == 404
      assert conn.halted

      # 404, not 403: a caller must not be able to distinguish "exists but
      # forbidden" from "does not exist" and enumerate other tenants' apps.
      assert Jason.decode!(conn.resp_body)["error"] == "app_not_found"
    end

    test "localhost is allowed through (ops)", %{app: app} do
      conn =
        Authz.authorize_app(conn_as("localhost"), app, :remove_domain, fn _e ->
          send_resp(conn_as("localhost"), 200, "ok")
        end)

      assert conn.status == 200
    end

    test "an unknown app is 404" do
      conn =
        Authz.authorize_app(conn_as("alice"), "no-such-app", :set_domain, fn _e ->
          raise "must not run"
        end)

      assert conn.status == 404
    end
  end

  describe "authorize_deploy/3" do
    test "a non-owner cannot redeploy an existing app", %{app: app} do
      conn =
        Authz.authorize_deploy(conn_as("mallory"), app, fn _e ->
          raise "callback must not run for a non-owner redeploy"
        end)

      assert conn.status == 404
      assert conn.halted
    end

    test "the owner can redeploy, and receives the existing entry", %{app: app} do
      conn =
        Authz.authorize_deploy(conn_as("alice"), app, fn entry ->
          assert entry.owner_id == "alice"
          send_resp(conn_as("alice"), 200, "ok")
        end)

      assert conn.status == 200
    end

    test "a FIRST deploy is allowed for any authenticated user, with a nil entry" do
      conn =
        Authz.authorize_deploy(conn_as("mallory"), "brand-new-app", fn entry ->
          assert entry == nil
          send_resp(conn_as("mallory"), 200, "ok")
        end)

      assert conn.status == 200
    end

    test "an unauthenticated caller cannot create an app" do
      conn =
        Authz.authorize_deploy(conn_as(nil), "brand-new-app", fn _e ->
          raise "must not run"
        end)

      assert conn.status == 403
      assert conn.halted
    end
  end

  describe "legacy entries" do
    setup do
      app = "authz-legacy-#{System.unique_integer([:positive])}"

      # No owner_id: an entry written before ownership existed.
      {:ok, _} = Mjolnir.Deploy.Registry.put(app, %{release_snapshot: "rel-1", port: 3000})
      on_exit(fn -> Mjolnir.Deploy.Registry.delete(app) end)
      %{legacy: app}
    end

    test "a regular user is denied — fail closed until back-filled", %{legacy: app} do
      conn =
        Authz.authorize_deploy(conn_as("alice"), app, fn _e -> raise "must not run" end)

      assert conn.status == 404
    end

    test "localhost can still act on them so ops can back-fill", %{legacy: app} do
      conn =
        Authz.authorize_app(conn_as("localhost"), app, :set_domain, fn _e ->
          send_resp(conn_as("localhost"), 200, "ok")
        end)

      assert conn.status == 200
    end
  end
end
