defmodule Mjolnir.Forge.APITest do
  @moduledoc """
  Plug.Test coverage for `Mjolnir.Forge.API` HTTP endpoints.

  Tests the HTTP shape — status codes, JSON response bodies, query/body
  parameter handling — without going through Bandit or the outer auth plug.
  Calls the Plug directly via `Mjolnir.Forge.API.call(conn, [])`.

  Not async — Forge.Store, Forge.Declarations, and HostSupervisor are
  singletons that mutate shared state.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Mjolnir.Forge.{Declarations, Store, Supervisor}

  @opts Mjolnir.Forge.API.init([])

  # ---------------------------------------------------------------------------
  # Setup: per-test tmp dirs so state doesn't bleed between tests.
  # ---------------------------------------------------------------------------

  setup do
    n = System.unique_integer([:positive])
    units_dir = Path.join(System.tmp_dir!(), "forge-api-units-#{n}")
    decls_dir = Path.join(System.tmp_dir!(), "forge-api-decls-#{n}")
    state_dir = Path.join(System.tmp_dir!(), "forge-api-state-#{n}")
    File.mkdir_p!(units_dir)
    File.mkdir_p!(decls_dir)
    File.mkdir_p!(state_dir)

    prev = {
      Application.get_env(:mjolnir, :forge_systemd_units_dir),
      Application.get_env(:mjolnir, :forge_declarations_path),
      Application.get_env(:mjolnir, :forge_state_dir)
    }

    Application.put_env(:mjolnir, :forge_systemd_units_dir, units_dir)
    Application.put_env(:mjolnir, :forge_declarations_path, decls_dir)
    Application.put_env(:mjolnir, :forge_state_dir, state_dir)
    Store.reload()
    Declarations.reload()

    on_exit(fn ->
      {prev_units, prev_decls, prev_state} = prev
      Application.put_env(:mjolnir, :forge_systemd_units_dir, prev_units)
      Application.put_env(:mjolnir, :forge_declarations_path, prev_decls)
      Application.put_env(:mjolnir, :forge_state_dir, prev_state)
      _ = File.rm_rf(units_dir)
      _ = File.rm_rf(decls_dir)
      _ = File.rm_rf(state_dir)
    end)

    %{units_dir: units_dir, decls_dir: decls_dir, state_dir: state_dir}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Send a JSON body via Plug.Parsers so body_params is populated correctly.
  defp call(method, path, body \\ nil) do
    conn = conn(method, path, body && Jason.encode!(body))

    conn =
      if body do
        put_req_header(conn, "content-type", "application/json")
      else
        conn
      end

    Mjolnir.Forge.API.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # Write a minimal declaration file for the given host into decls_dir.
  # Write a single-host declaration file and reload immediately.
  # Uses a monotonic counter in the module name so that Code.compile_file
  # never encounters the same module atom twice in a test run, which
  # eliminates "redefining module" warnings.
  defp write_decl(decls_dir, host, unit_name, content) do
    write_decls_batch(decls_dir, [{host, unit_name, content}])
  end

  # Write multiple host declaration files then do a single Declarations.reload.
  # Accepts a list of {host, unit_name, content} tuples. All existing .exs
  # files are removed first so the directory only contains what this call wrote
  # — this prevents reload from re-compiling stale modules from prior calls.
  defp write_decls_batch(decls_dir, entries) do
    # Remove stale files so reload won't re-compile previously loaded modules.
    decls_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".exs"))
    |> Enum.each(&File.rm!(Path.join(decls_dir, &1)))

    Enum.each(entries, fn {host, unit_name, content} ->
      n = System.unique_integer([:positive, :monotonic])
      safe = host |> String.replace(~r/[^a-zA-Z0-9]/, "")
      mod_name = "ForgeAPIDecl#{safe}V#{abs(n)}"

      src = """
      defmodule #{mod_name} do
        use Mjolnir.Forge.Declaration, host: "#{host}"
        systemd_unit "#{unit_name}" do
          source #{inspect(content)}
        end
      end
      """

      File.write!(Path.join(decls_dir, "#{host}.exs"), src)
    end)

    :ok = Declarations.reload()
  end

  defp start_host(host) do
    case Supervisor.start_host(host: host, transport: :local) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  # ---------------------------------------------------------------------------
  # GET /hosts
  # ---------------------------------------------------------------------------

  describe "GET /hosts" do
    test "returns 200 with hosts list shape when no hosts are registered" do
      conn = call(:get, "/hosts")
      assert conn.status == 200
      body = json_body(conn)
      assert Map.has_key?(body, "hosts")
      assert is_list(body["hosts"])
    end

    test "running host appears in list with running: true after start_host", %{} do
      host = "api-test-host-#{System.unique_integer([:positive])}"
      start_host(host)

      conn = call(:get, "/hosts")
      assert conn.status == 200
      hosts = json_body(conn)["hosts"]
      entry = Enum.find(hosts, &(&1["host"] == host))
      assert entry != nil
      assert entry["running"] == true
    end

    test "declared host appears with declared: true regardless of running state",
         %{decls_dir: decls_dir} do
      host = "api-decl-host-#{System.unique_integer([:positive])}"
      write_decl(decls_dir, host, "test.service", "[Unit]\nDescription=Test\n")

      conn = call(:get, "/hosts")
      assert conn.status == 200
      hosts = json_body(conn)["hosts"]
      entry = Enum.find(hosts, &(&1["host"] == host))
      assert entry != nil
      assert entry["declared"] == true
    end
  end

  # ---------------------------------------------------------------------------
  # POST /hosts
  # ---------------------------------------------------------------------------

  describe "POST /hosts" do
    test "returns 201 with status started when host is new" do
      host = "api-post-host-#{System.unique_integer([:positive])}"
      conn = call(:post, "/hosts", %{"host" => host})
      assert conn.status == 201
      body = json_body(conn)
      assert body["host"] == host
      assert body["status"] == "started"
    end

    test "returns 200 with status already_running when POSTing same host twice" do
      host = "api-post-dup-#{System.unique_integer([:positive])}"
      call(:post, "/hosts", %{"host" => host})
      conn = call(:post, "/hosts", %{"host" => host})
      assert conn.status == 200
      body = json_body(conn)
      assert body["host"] == host
      assert body["status"] == "already_running"
    end

    test "returns 400 with error message when host field is missing" do
      conn = call(:post, "/hosts", %{"transport" => "local"})
      assert conn.status == 400
      assert json_body(conn)["error"] == "host is required"
    end

    test "returns 400 when body is empty" do
      conn = call(:post, "/hosts", %{})
      assert conn.status == 400
      assert json_body(conn)["error"] == "host is required"
    end

    test "accepts transport ssh in body and starts worker" do
      host = "api-post-ssh-#{System.unique_integer([:positive])}"
      conn = call(:post, "/hosts", %{"host" => host, "transport" => "ssh"})
      # SSH transport workers start fine; SSH calls fail only at apply time
      assert conn.status == 201
      assert json_body(conn)["status"] == "started"
    end

    test "accepts auto_apply true in body and starts worker" do
      host = "api-post-autoapply-#{System.unique_integer([:positive])}"
      conn = call(:post, "/hosts", %{"host" => host, "auto_apply" => true})
      assert conn.status == 201
    end
  end

  # ---------------------------------------------------------------------------
  # GET /plan?host=H
  # ---------------------------------------------------------------------------

  describe "GET /plan" do
    test "returns 400 when host query param is missing" do
      conn = call(:get, "/plan")
      assert conn.status == 400
      assert json_body(conn)["error"] == "host query param required"
    end

    test "returns 400 when host query param is empty string" do
      conn = call(:get, "/plan?host=")
      assert conn.status == 400
      assert json_body(conn)["error"] == "host query param required"
    end

    test "returns 200 with host and entries list shape for a running host",
         %{decls_dir: decls_dir} do
      host = "api-plan-host-#{System.unique_integer([:positive])}"
      write_decl(decls_dir, host, "planned.service", "[Unit]\nDescription=Planned\n")
      start_host(host)

      conn = call(:get, "/plan?host=#{URI.encode(host)}")
      assert conn.status == 200
      body = json_body(conn)
      assert body["host"] == host
      assert is_list(body["entries"])
    end

    test "each plan entry has required keys with correct types", %{decls_dir: decls_dir} do
      host = "api-plan-keys-#{System.unique_integer([:positive])}"
      write_decl(decls_dir, host, "shape.service", "[Unit]\nDescription=Shape\n")
      start_host(host)

      body = json_body(call(:get, "/plan?host=#{URI.encode(host)}"))
      [entry] = body["entries"]

      assert is_binary(entry["kind"])
      assert is_binary(entry["id"])
      assert is_binary(entry["status"])
      # hashes are nil or hex strings — not raw binary
      for key <- ~w(declared_hash owned_hash observed_hash) do
        assert is_nil(entry[key]) or (is_binary(entry[key]) and entry[key] =~ ~r/\A[0-9a-f]+\z/)
      end
    end

    test "plan entry status is an atom-as-string not an atom", %{decls_dir: decls_dir} do
      host = "api-plan-status-#{System.unique_integer([:positive])}"
      write_decl(decls_dir, host, "status.service", "[Unit]\nDescription=Status\n")
      start_host(host)

      body = json_body(call(:get, "/plan?host=#{URI.encode(host)}"))
      [entry] = body["entries"]
      # JSON has no atom type; must be a plain string like "new"
      assert entry["status"] == "new"
    end
  end

  # ---------------------------------------------------------------------------
  # POST /apply
  # ---------------------------------------------------------------------------

  describe "POST /apply" do
    test "returns 400 when host is missing from body" do
      conn = call(:post, "/apply", %{"keys" => "all_safe"})
      assert conn.status == 400
      assert json_body(conn)["error"] == "host is required"
    end

    test "returns 400 when keys field is missing" do
      host = "api-apply-nokeys-#{System.unique_integer([:positive])}"
      start_host(host)
      conn = call(:post, "/apply", %{"host" => host})
      assert conn.status == 400
      assert json_body(conn)["error"] == "keys is required"
    end

    test "returns 400 when keys references an unknown kind" do
      host = "api-apply-badkind-#{System.unique_integer([:positive])}"
      start_host(host)

      conn =
        call(:post, "/apply", %{
          "host" => host,
          "keys" => [%{"kind" => "unknown_kind", "id" => "foo.service"}]
        })

      assert conn.status == 400
      assert json_body(conn)["error"] =~ "keys must be"
    end

    test "accepts keys: all_safe string and returns 200 with results list",
         %{decls_dir: decls_dir} do
      host = "api-apply-allsafe-#{System.unique_integer([:positive])}"
      write_decl(decls_dir, host, "allsafe.service", "[Unit]\nDescription=AllSafe\n")
      start_host(host)

      conn = call(:post, "/apply", %{"host" => host, "keys" => "all_safe"})
      assert conn.status == 200
      body = json_body(conn)
      assert body["host"] == host
      assert is_list(body["results"])
    end

    test "accepts keys as list of {kind, id} maps and returns 200", %{decls_dir: decls_dir} do
      host = "api-apply-list-#{System.unique_integer([:positive])}"
      write_decl(decls_dir, host, "listed.service", "[Unit]\nDescription=Listed\n")
      start_host(host)

      conn =
        call(:post, "/apply", %{
          "host" => host,
          "keys" => [%{"kind" => "systemd_unit", "id" => "listed.service"}]
        })

      assert conn.status == 200
    end

    test "each result in the results list has kind, id, and result keys",
         %{decls_dir: decls_dir} do
      host = "api-apply-shape-#{System.unique_integer([:positive])}"
      write_decl(decls_dir, host, "shaped.service", "[Unit]\nDescription=Shaped\n")
      start_host(host)

      body = json_body(call(:post, "/apply", %{"host" => host, "keys" => "all_safe"}))
      [result] = body["results"]
      assert is_binary(result["kind"])
      assert is_binary(result["id"])
      assert is_binary(result["result"])
    end
  end

  # ---------------------------------------------------------------------------
  # GET /state
  # ---------------------------------------------------------------------------

  describe "GET /state" do
    test "returns 200 with records list when store is empty" do
      conn = call(:get, "/state")
      assert conn.status == 200
      body = json_body(conn)
      assert Map.has_key?(body, "records")
      assert body["records"] == []
    end

    test "filter by host returns only matching records", %{decls_dir: decls_dir} do
      host_a = "api-state-a-#{System.unique_integer([:positive])}"
      host_b = "api-state-b-#{System.unique_integer([:positive])}"
      # Write both files in one batch so Declarations.reload only runs once
      # and never re-compiles a previously loaded module.
      write_decls_batch(decls_dir, [
        {host_a, "a.service", "[Unit]\nDescription=A\n"},
        {host_b, "b.service", "[Unit]\nDescription=B\n"}
      ])
      start_host(host_a)
      start_host(host_b)
      # Trigger plan to populate store rows
      call(:get, "/plan?host=#{URI.encode(host_a)}")
      call(:get, "/plan?host=#{URI.encode(host_b)}")

      body = json_body(call(:get, "/state?host=#{URI.encode(host_a)}"))
      records = body["records"]
      assert Enum.all?(records, &(&1["host"] == host_a))
    end

    test "filter by kind returns only matching records", %{decls_dir: decls_dir} do
      host = "api-state-kind-#{System.unique_integer([:positive])}"
      write_decl(decls_dir, host, "kind.service", "[Unit]\nDescription=Kind\n")
      start_host(host)
      call(:get, "/plan?host=#{URI.encode(host)}")

      body = json_body(call(:get, "/state?kind=systemd_unit"))
      records = body["records"]
      assert Enum.all?(records, &(&1["kind"] == "systemd_unit"))
    end

    test "filter by status returns only records matching that atom-as-string",
         %{decls_dir: decls_dir} do
      host = "api-state-status-#{System.unique_integer([:positive])}"
      write_decl(decls_dir, host, "stat.service", "[Unit]\nDescription=Stat\n")
      start_host(host)
      call(:get, "/plan?host=#{URI.encode(host)}")

      body = json_body(call(:get, "/state?status=new"))
      records = body["records"]
      assert Enum.all?(records, &(&1["status"] == "new"))
    end

    test "combined host + kind filter works", %{decls_dir: decls_dir} do
      host = "api-state-combo-#{System.unique_integer([:positive])}"
      write_decl(decls_dir, host, "combo.service", "[Unit]\nDescription=Combo\n")
      start_host(host)
      call(:get, "/plan?host=#{URI.encode(host)}")

      body = json_body(call(:get, "/state?host=#{URI.encode(host)}&kind=systemd_unit"))
      records = body["records"]
      assert Enum.all?(records, &(&1["host"] == host and &1["kind"] == "systemd_unit"))
    end
  end

  # ---------------------------------------------------------------------------
  # Not found
  # ---------------------------------------------------------------------------

  describe "unmatched routes" do
    test "returns 404 with error not_found for unknown path" do
      conn = call(:get, "/nonexistent")
      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
    end

    test "returns 404 with error not_found for unknown nested path" do
      conn = call(:get, "/hosts/deep/nested/path")
      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
    end
  end
end
