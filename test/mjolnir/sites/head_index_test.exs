defmodule Mjolnir.Sites.HeadIndexTest do
  @moduledoc """
  Integration test for the Postgres-backed sites HEAD index. Brings up the
  full Postgres supervision tree, then exercises `Mjolnir.Sites.HeadIndex`
  upserts (including monotonicity) and reads.
  """

  use ExUnit.Case, async: false
  @moduletag :postgres

  alias Mjolnir.Sites.{HeadIndex, HeadRecord}

  setup do
    base = Path.join(System.tmp_dir!(), "mjolnir-head-idx-#{:erlang.unique_integer([:positive])}")
    data_dir = Path.join(base, "data")
    socket_dir = Path.join(base, "sock")
    log_dir = Path.join(base, "log")
    File.mkdir_p!(socket_dir)
    File.mkdir_p!(log_dir)

    prev = capture_env()

    Application.put_env(:mjolnir, :pg_enabled, true)
    Application.put_env(:mjolnir, :pg_managed, true)
    Application.put_env(:mjolnir, :pg_data_dir, data_dir)
    Application.put_env(:mjolnir, :pg_socket_dir, socket_dir)
    Application.put_env(:mjolnir, :pg_log_dir, log_dir)
    Application.put_env(:mjolnir, :pg_bin_dir, find_bin_dir())
    Application.put_env(:mjolnir, :pg_run_as, nil)
    Application.put_env(:mjolnir, :pg_bootstrap_role, "mjolnir_admin")
    Application.put_env(:mjolnir, :pg_roles, ["mjolnir_admin", "mjolnir_sites"])
    Application.put_env(:mjolnir, :pg_ident_users, [System.get_env("USER")])
    Application.put_env(:mjolnir, :pg_database, "mjolnir")

    {:ok, _sup} = start_supervised(Mjolnir.Postgres.Supervisor)

    on_exit(fn ->
      restore_env(prev)
      File.rm_rf!(base)
    end)

    :ok
  end

  test "upsert + get round-trip" do
    record = %HeadRecord{
      version: 1,
      identikey_fp: "fp-alpha",
      site_name: "blog",
      snapshot_hash: "hash-1",
      sequence: 1,
      created_at: DateTime.utc_now(),
      signature: nil
    }

    assert :ok = HeadIndex.upsert(record)

    assert {:ok, row} = HeadIndex.get("fp-alpha", "blog")
    assert row.snapshot_hash == "hash-1"
    assert row.sequence == 1
  end

  test "upsert is monotonic — higher sequence wins, lower is ignored" do
    base_record = %HeadRecord{
      version: 1,
      identikey_fp: "fp-beta",
      site_name: "site",
      snapshot_hash: "h0",
      sequence: 5,
      created_at: DateTime.utc_now(),
      signature: nil
    }

    assert :ok = HeadIndex.upsert(base_record)

    # Higher sequence advances the row
    assert :ok = HeadIndex.upsert(%{base_record | snapshot_hash: "h1", sequence: 7})
    assert {:ok, %{snapshot_hash: "h1", sequence: 7}} = HeadIndex.get("fp-beta", "site")

    # Lower sequence is silently rejected by the on-conflict guard
    assert :ok = HeadIndex.upsert(%{base_record | snapshot_hash: "h_old", sequence: 3})
    assert {:ok, %{snapshot_hash: "h1", sequence: 7}} = HeadIndex.get("fp-beta", "site")

    # Equal sequence is also rejected (strict >)
    assert :ok = HeadIndex.upsert(%{base_record | snapshot_hash: "h1_dup", sequence: 7})
    assert {:ok, %{snapshot_hash: "h1", sequence: 7}} = HeadIndex.get("fp-beta", "site")
  end

  test "list_by_fp returns all sites under one identikey" do
    now = DateTime.utc_now()

    Enum.each(["a", "b", "c"], fn site ->
      HeadIndex.upsert(%HeadRecord{
        version: 1,
        identikey_fp: "fp-multi",
        site_name: site,
        snapshot_hash: "hash-#{site}",
        sequence: 1,
        created_at: now,
        signature: nil
      })
    end)

    rows = HeadIndex.list_by_fp("fp-multi")
    assert length(rows) == 3
    assert Enum.map(rows, & &1.site_name) |> Enum.sort() == ["a", "b", "c"]
  end

  test "get on missing row returns :not_found" do
    assert :not_found = HeadIndex.get("fp-nope", "nowhere")
  end

  test "with pg_enabled=false, reads return :not_indexed and writes are no-ops" do
    Application.put_env(:mjolnir, :pg_enabled, false)

    record = %HeadRecord{
      version: 1,
      identikey_fp: "fp-disabled",
      site_name: "x",
      snapshot_hash: "h",
      sequence: 1,
      created_at: DateTime.utc_now(),
      signature: nil
    }

    assert :ok = HeadIndex.upsert(record)
    assert {:error, :not_indexed} = HeadIndex.get("fp-disabled", "x")
    assert [] = HeadIndex.list_by_fp("fp-disabled")
  end

  ## Helpers

  defp find_bin_dir do
    cond do
      File.regular?("/usr/bin/postgres") -> "/usr/bin"
      File.regular?("/usr/local/bin/postgres") -> "/usr/local/bin"
      true -> "/usr/bin"
    end
  end

  defp capture_env do
    keys = [
      :pg_enabled,
      :pg_managed,
      :pg_data_dir,
      :pg_socket_dir,
      :pg_log_dir,
      :pg_bin_dir,
      :pg_run_as,
      :pg_bootstrap_role,
      :pg_roles,
      :pg_ident_users,
      :pg_database
    ]

    for k <- keys, into: %{}, do: {k, Application.get_env(:mjolnir, k)}
  end

  defp restore_env(prev) do
    for {k, v} <- prev do
      case v do
        nil -> Application.delete_env(:mjolnir, k)
        v -> Application.put_env(:mjolnir, k, v)
      end
    end
  end
end
