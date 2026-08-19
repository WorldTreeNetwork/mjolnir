defmodule Mjolnir.Postgres.TenantsUrlTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Postgres.Tenants

  test "DATABASE_URL is overlay TCP, not a unix socket" do
    url = Tenants.database_url("hypersigil", "p/a+ss", "10.200.0.1")
    assert url == "postgres://hypersigil:p%2Fa%2Bss@10.200.0.1:5432/hypersigil"
    refute url =~ "socket"
    refute url =~ "/var/run"
  end

  test "list is empty when the registry file is missing" do
    Application.put_env(:mjolnir, :pg_tenants_file, "/tmp/does-not-exist-mjolnir-tenants.json")

    on_exit(fn -> Application.delete_env(:mjolnir, :pg_tenants_file) end)

    assert Tenants.list() == []
  end
end
