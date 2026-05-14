defmodule Mjolnir.Sites.ManifestIndexTest do
  @moduledoc """
  Integration test for the Postgres-backed sites manifest index.
  """

  use ExUnit.Case, async: false
  @moduletag :postgres

  alias Mjolnir.Sites.{Manifest, ManifestIndex}

  setup do
    base = Path.join(System.tmp_dir!(), "mjolnir-mani-idx-#{:erlang.unique_integer([:positive])}")
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
    manifest = sample_manifest("fp-x", "blog", 3)
    hash = "snap-1"

    assert :ok = ManifestIndex.upsert(hash, manifest)

    assert {:ok, row} = ManifestIndex.get(hash)
    assert row.identikey_fp == "fp-x"
    assert row.site_name == "blog"
    assert row.mode == "public"
    assert row.entry_count == 3
  end

  test "list_for_site returns all snapshots for a site, newest first" do
    now = DateTime.utc_now()

    Enum.with_index([:t0, :t1, :t2])
    |> Enum.each(fn {label, i} ->
      manifest = %{
        sample_manifest("fp-list", "blog", 1)
        | created_at: DateTime.add(now, i, :hour)
      }

      ManifestIndex.upsert("snap-#{label}", manifest)
    end)

    # Unrelated site for the same fp — should NOT come back
    ManifestIndex.upsert("snap-other", sample_manifest("fp-list", "other", 1))

    rows = ManifestIndex.list_for_site("fp-list", "blog")
    assert length(rows) == 3
    assert Enum.all?(rows, &(&1.site_name == "blog"))
    # Newest first
    [first, second, third] = rows
    assert DateTime.compare(first.created_at, second.created_at) == :gt
    assert DateTime.compare(second.created_at, third.created_at) == :gt
  end

  test "upsert is idempotent — same snapshot twice does not duplicate" do
    manifest = sample_manifest("fp-idem", "site", 2)
    assert :ok = ManifestIndex.upsert("snap-idem", manifest)
    assert :ok = ManifestIndex.upsert("snap-idem", manifest)

    rows = ManifestIndex.list_for_site("fp-idem", "site")
    assert length(rows) == 1
  end

  test "with pg_enabled=false, reads return :not_indexed" do
    Application.put_env(:mjolnir, :pg_enabled, false)
    assert :ok = ManifestIndex.upsert("snap-disabled", sample_manifest("fp", "s", 1))
    assert {:error, :not_indexed} = ManifestIndex.get("snap-disabled")
    assert [] = ManifestIndex.list_for_site("fp", "s")
  end

  ## Helpers

  defp sample_manifest(fp, site, n_entries) do
    entries =
      for i <- 1..n_entries do
        %Manifest.Entry{
          path: "/file-#{i}.html",
          content_type: "text/html",
          bao_hash: "bao-#{i}",
          ciphertext_size: 100,
          plaintext_size: 90,
          nonce: :crypto.strong_rand_bytes(24),
          wrapped_key: nil,
          content_encoding: nil
        }
      end

    %Manifest{
      version: 1,
      identikey_fp: fp,
      site_name: site,
      mode: :public,
      created_at: DateTime.utc_now(),
      sym_seed: :crypto.strong_rand_bytes(32),
      entries: entries,
      signatures: nil
    }
  end

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
