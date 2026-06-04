defmodule Mjolnir.Forge.AdoptIgnoreTest do
  @moduledoc """
  End-to-end coverage of the diff / adopt / ignore endpoints against real
  unmanaged resources, driven through `Mjolnir.Forge.API` via `Plug.Test`.

  An "unmanaged" systemd unit is simulated by writing a unit file directly
  into the sandbox `units_dir` without declaring it. Note `plan` does NOT
  enumerate undeclared resources (no host-wide discovery yet); a single-key
  `/diff` observes the named resource directly and classifies it `:unmanaged`,
  which is the precondition for adopt/ignore.

  Not async — Store / Declarations / units_dir are global singletons.
  """

  use ExUnit.Case, async: false
  import Plug.Test

  alias Mjolnir.Forge.{Authoring, Declarations, Store, Supervisor}

  @opts Mjolnir.Forge.API.init([])
  @host "self"

  setup do
    n = System.unique_integer([:positive])
    units_dir = Path.join(System.tmp_dir!(), "forge-adopt-units-#{n}")
    decls_dir = Path.join(System.tmp_dir!(), "forge-adopt-decls-#{n}")
    state_dir = Path.join(System.tmp_dir!(), "forge-adopt-state-#{n}")
    Enum.each([units_dir, decls_dir, state_dir], &File.mkdir_p!/1)

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
    start_host(@host)

    on_exit(fn ->
      {pu, pd, ps} = prev
      Application.put_env(:mjolnir, :forge_systemd_units_dir, pu)
      Application.put_env(:mjolnir, :forge_declarations_path, pd)
      Application.put_env(:mjolnir, :forge_state_dir, ps)
      Enum.each([units_dir, decls_dir, state_dir], &File.rm_rf/1)
      Store.reload()
      Declarations.reload()
    end)

    %{units_dir: units_dir, decls_dir: decls_dir, n: n}
  end

  defp start_host(host) do
    case Supervisor.start_host(host: host, transport: :local) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp call(method, path, body \\ nil) do
    conn = conn(method, path, body && Jason.encode!(body))

    conn =
      if body, do: Plug.Conn.put_req_header(conn, "content-type", "application/json"), else: conn

    Mjolnir.Forge.API.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # Write an undeclared unit file → it is observed but not declared → :unmanaged.
  defp write_unmanaged_unit(units_dir, name, source) do
    File.write!(Path.join(units_dir, name), source)
  end

  defp plan_status(id) do
    body = json_body(call(:get, "/plan?host=#{@host}"))
    entry = Enum.find(body["entries"], &(&1["id"] == id))
    entry && entry["status"]
  end

  # Status via /diff, which observes a named resource directly — works even for
  # resources the plan doesn't enumerate (undeclared, unowned units).
  defp diff_status(id) do
    json_body(call(:get, "/diff?host=#{@host}&kind=systemd_unit&id=#{id}"))["status"]
  end

  describe "GET /diff" do
    test "returns observed content and unmanaged status for an undeclared unit",
         %{units_dir: units_dir, n: n} do
      id = "diff-#{n}.service"
      source = "[Unit]\nDescription=Diff Me\n"
      write_unmanaged_unit(units_dir, id, source)

      conn = call(:get, "/diff?host=#{@host}&kind=systemd_unit&id=#{id}")
      assert conn.status == 200
      body = json_body(conn)
      assert body["status"] == "unmanaged"
      assert body["observed"] == source
      assert body["declared"] == nil
    end

    test "404 when the resource is neither declared nor observed" do
      conn = call(:get, "/diff?host=#{@host}&kind=systemd_unit&id=ghost.service")
      assert conn.status == 404
    end

    test "400 on unknown kind" do
      conn = call(:get, "/diff?host=#{@host}&kind=bogus&id=x")
      assert conn.status == 400
      assert json_body(conn)["error"] =~ "unknown kind"
    end
  end

  describe "POST /adopt" do
    test "adopts an unmanaged unit: authors a declaration and takes ownership",
         %{units_dir: units_dir, decls_dir: decls_dir, n: n} do
      id = "adopt-#{n}.service"
      write_unmanaged_unit(units_dir, id, "[Unit]\nDescription=Adopt Me\n")

      assert diff_status(id) == "unmanaged"

      conn = call(:post, "/adopt", %{"host" => @host, "kind" => "systemd_unit", "id" => id})
      assert conn.status == 200
      assert json_body(conn)["result"] == "ok"

      # A Forge-owned declaration file now exists...
      adopted = Authoring.adopted_path(@host, "systemd_unit", id)
      assert String.starts_with?(adopted, decls_dir)
      assert File.exists?(adopted)

      # ...and the resource is now converged (declared + owned + observed match).
      assert plan_status(id) == "converged"

      # decl-path points at the adopted file.
      dp = json_body(call(:get, "/decl-path?host=#{@host}&kind=systemd_unit&id=#{id}"))
      assert dp["path"] == adopted
    end

    test "422 when adopting a resource that can't be observed" do
      conn =
        call(:post, "/adopt", %{"host" => @host, "kind" => "systemd_unit", "id" => "nope.service"})

      assert conn.status == 422
      assert json_body(conn)["error"] == "adopt_failed"
    end

    test "400 when body is missing fields" do
      conn = call(:post, "/adopt", %{"host" => @host})
      assert conn.status == 400
    end
  end

  describe "POST /ignore" do
    test "marks an unmanaged unit ignored and the mark is sticky across re-plans",
         %{units_dir: units_dir, n: n} do
      id = "ignore-#{n}.service"
      write_unmanaged_unit(units_dir, id, "[Unit]\nDescription=Ignore Me\n")
      assert diff_status(id) == "unmanaged"

      conn = call(:post, "/ignore", %{"host" => @host, "kind" => "systemd_unit", "id" => id})
      assert conn.status == 200
      assert json_body(conn)["result"] == "ignored"

      # /state reflects the ignored status...
      records = json_body(call(:get, "/state?host=#{@host}"))["records"]
      rec = Enum.find(records, &(&1["resource_id"] == id))
      assert rec["status"] == "ignored"

      # ...and a re-plan does NOT revert it back to unmanaged.
      _ = call(:get, "/plan?host=#{@host}")
      records2 = json_body(call(:get, "/state?host=#{@host}"))["records"]
      rec2 = Enum.find(records2, &(&1["resource_id"] == id))
      assert rec2["status"] == "ignored"
    end
  end

  describe "GET /decl-path" do
    test "returns null path for an undeclared resource" do
      body =
        json_body(call(:get, "/decl-path?host=#{@host}&kind=systemd_unit&id=undeclared.service"))

      assert body["path"] == nil
    end
  end
end
