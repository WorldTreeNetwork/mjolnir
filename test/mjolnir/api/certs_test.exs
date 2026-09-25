defmodule Mjolnir.API.CertsTest do
  use ExUnit.Case, async: true

  alias Mjolnir.API.Certs

  @cert "-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----\n"
  @key "-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----\n"

  defp fake_ops(agent) do
    %{
      issue_cmd: fn fqdn ->
        Agent.update(agent, fn s ->
          %{s | issued: [fqdn | s.issued]}
        end)

        {:ok, %{cert: @cert, key: @key, not_after: "2030-01-01T00:00:00Z"}}
      end,
      ensure: fn fqdn, cert, key ->
        Agent.update(agent, fn s ->
          %{s | ensured: [{fqdn, cert, key} | s.ensured]}
        end)

        {:ok, :installed}
      end,
      list_certs: fn ->
        {:ok,
         [
           %{
             host: "taskmaster.dev",
             cert_path: "/etc/mjolnir/certs/taskmaster.dev/fullchain.pem",
             key_path: "/etc/mjolnir/certs/taskmaster.dev/privkey.pem",
             not_after: "Jan 1 00:00:00 2030 GMT",
             issuer: "Test CA",
             sans: ["taskmaster.dev"]
           }
         ]}
      end
    }
  end

  setup do
    {:ok, agent} = start_supervised({Agent, fn -> %{issued: [], ensured: []} end})
    %{agent: agent, ops: fake_ops(agent)}
  end

  describe "issue/2" do
    test "plants via issue_cmd and installs [[cert]] without returning PEMs", %{
      agent: agent,
      ops: ops
    } do
      assert {:ok, res} = Certs.issue("Taskmaster.dev", ops: ops)

      assert res == %{
               fqdn: "taskmaster.dev",
               status: :installed,
               not_after: "2030-01-01T00:00:00Z"
             }

      refute Map.has_key?(res, :cert)
      refute Map.has_key?(res, :key)
      refute Map.has_key?(res, :fullchain)
      refute Map.has_key?(res, :privkey)

      assert Agent.get(agent, & &1.issued) == ["taskmaster.dev"]
      assert [{fqdn, cert, key}] = Agent.get(agent, & &1.ensured)
      assert fqdn == "taskmaster.dev"
      assert cert == @cert
      assert key == @key
    end

    test "refuses wildcards and never calls issue_cmd", %{agent: agent, ops: ops} do
      assert {:error, :wildcard_not_supported} = Certs.issue("*.taskmaster.dev", ops: ops)
      assert Agent.get(agent, & &1.issued) == []
      assert Agent.get(agent, & &1.ensured) == []
    end

    test "returns issue_cmd failure without calling ensure", %{agent: agent} do
      ops = %{
        issue_cmd: fn _ -> {:error, {:issue_failed, 1, "acme timeout"}} end,
        ensure: fn _, _, _ -> flunk("ensure must not run after issue_cmd fails") end,
        list_certs: fn -> {:ok, []} end
      }

      assert {:error, {:issue_failed, 1, "acme timeout"}} =
               Certs.issue("taskmaster.dev", ops: ops)

      assert Agent.get(agent, & &1.ensured) == []
    end

    test "wraps ensure failure after a successful issue_cmd" do
      ops = %{
        issue_cmd: fn _ -> {:ok, %{cert: @cert, key: @key, not_after: nil}} end,
        ensure: fn _, _, _ -> {:error, :key_pair_mismatch} end,
        list_certs: fn -> {:ok, []} end
      }

      assert {:error, {:ensure_failed, :key_pair_mismatch}} =
               Certs.issue("taskmaster.dev", ops: ops)
    end
  end

  describe "renew_due/1" do
    @now ~U[2026-09-25 12:00:00Z]

    defp renew_ops(agent, certs) do
      %{
        issue_cmd: fn fqdn ->
          Agent.update(agent, fn s -> %{s | issued: [fqdn | s.issued]} end)
          {:ok, %{cert: @cert, key: @key, not_after: "2030-01-01T00:00:00Z"}}
        end,
        ensure: fn fqdn, cert, key ->
          Agent.update(agent, fn s -> %{s | ensured: [{fqdn, cert, key} | s.ensured]} end)
          {:ok, :installed}
        end,
        list_certs: fn -> {:ok, certs} end
      }
    end

    test "does nothing when every cert is outside the window", %{agent: agent} do
      ops =
        renew_ops(agent, [
          %{host: "taskmaster.dev", not_after: "Jan 1 00:00:00 2030 GMT"}
        ])

      assert {:ok, :none} = Certs.renew_due(now: @now, ops: ops)
      assert Agent.get(agent, & &1.issued) == []
    end

    test "issues only the soonest certificate inside 30 days", %{agent: agent} do
      ops =
        renew_ops(agent, [
          %{host: "fresh.example", not_after: "Jan 1 00:00:00 2030 GMT"},
          %{host: "zine.identikey.io", not_after: "Sep 22 22:42:17 2026 GMT"},
          %{host: "older.example", not_after: "Sep 1 00:00:00 2026 GMT"}
        ])

      assert {:ok, %{fqdn: "older.example", status: :installed}} =
               Certs.renew_due(now: @now, ops: ops)

      assert Agent.get(agent, & &1.issued) == ["older.example"]
    end

    test "treats an unreadable expiry as due and skips wildcards", %{agent: agent} do
      ops =
        renew_ops(agent, [
          %{host: "*.example.com", not_after: "Jan 1 00:00:00 2020 GMT"},
          %{host: "undated.example", not_after: nil}
        ])

      assert {:ok, %{fqdn: "undated.example"}} = Certs.renew_due(now: @now, ops: ops)
    end

    test "a certificate 31 days out is not due", %{agent: agent} do
      ops =
        renew_ops(agent, [
          %{host: "edge.example", not_after: "Oct 26 12:00:00 2026 GMT"}
        ])

      assert {:ok, :none} = Certs.renew_due(now: @now, ops: ops)
    end

    test "a certificate exactly 30 days out is due", %{agent: agent} do
      ops =
        renew_ops(agent, [
          %{host: "edge.example", not_after: "Oct 25 12:00:00 2026 GMT"}
        ])

      assert {:ok, %{fqdn: "edge.example"}} = Certs.renew_due(now: @now, ops: ops)
    end
  end

  describe "list/1" do
    test "strips PEM paths from the public shape", %{ops: ops} do
      assert {:ok, [c]} = Certs.list(ops: ops)
      assert c.host == "taskmaster.dev"
      assert c.not_after == "Jan 1 00:00:00 2030 GMT"
      assert c.issuer == "Test CA"
      assert c.sans == ["taskmaster.dev"]
      refute Map.has_key?(c, :cert_path)
      refute Map.has_key?(c, :key_path)
      refute Map.has_key?(c, :cert)
      refute Map.has_key?(c, :key)
    end
  end
end
