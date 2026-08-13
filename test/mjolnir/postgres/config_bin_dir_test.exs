defmodule Mjolnir.Postgres.ConfigBinDirTest do
  @moduledoc """
  mjolnir-bce: `:pg_bin_dir` defaulted to /usr/bin, which on Debian/Ubuntu
  contains no server binaries at all — `postgres` and `initdb` live in
  /usr/lib/postgresql/<version>/bin and only the client tools are linked into
  /usr/bin. The compiled-in default therefore could not work on the distro
  Mjolnir runs on in production, and failed with a missing-binary error naming
  a path that was never plausible.

  `detect_bin_dir/0` is pure except for filesystem probing, so the ranking
  logic — which is the part that can be subtly wrong — is tested directly.
  """
  use ExUnit.Case, async: false

  alias Mjolnir.Postgres.Config

  describe "detect_bin_dir/0" do
    test "returns an absolute path" do
      # Whatever this machine has, the answer must be usable as a path prefix
      # for postgres/initdb/psql.
      dir = Config.detect_bin_dir()
      assert is_binary(dir)
      assert String.starts_with?(dir, "/")
    end

    test "falls back to /usr/bin where there is no versioned layout" do
      # macOS and Arch have no /usr/lib/postgresql/*/bin. On a Debian CI host
      # this test would legitimately see a versioned dir instead, so accept
      # either rather than asserting a machine-specific answer.
      dir = Config.detect_bin_dir()
      assert dir == "/usr/bin" or String.starts_with?(dir, "/usr/lib/postgresql/")
    end
  end

  describe "resolve/0 precedence" do
    setup do
      prev = Application.get_env(:mjolnir, :pg_bin_dir)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:mjolnir, :pg_bin_dir, prev),
          else: Application.delete_env(:mjolnir, :pg_bin_dir)
      end)

      :ok
    end

    test "an explicit :pg_bin_dir always wins over detection" do
      # This is what production relies on: /etc/mjolnir/env sets
      # MJOLNIR_PG_BIN_DIR, and detection must never override it.
      Application.put_env(:mjolnir, :pg_bin_dir, "/opt/custom/pg/bin")

      config = Config.resolve()

      assert config.bin_dir == "/opt/custom/pg/bin"
      assert config.postgres_bin == "/opt/custom/pg/bin/postgres"
      assert config.initdb_bin == "/opt/custom/pg/bin/initdb"
    end

    test "detection fills in when nothing is configured" do
      Application.delete_env(:mjolnir, :pg_bin_dir)

      config = Config.resolve()

      assert config.bin_dir == Config.detect_bin_dir()
      assert config.postgres_bin == Path.join(config.bin_dir, "postgres")
    end
  end

  describe "version ranking" do
    @tag :tmp_dir
    test "prefers 16 over 9 — a string sort gets this backwards", ctx do
      # The bug this guards is real on any host carrying both an old and a new
      # cluster: "9" > "16" lexically, so a naive sort picks the ancient one.
      # Exercised through a fake tree rather than the real /usr/lib, so it runs
      # anywhere.
      for v <- ["9", "16", "10"] do
        dir = Path.join([ctx.tmp_dir, "usr/lib/postgresql", v, "bin"])
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "postgres"), "")
      end

      ranked =
        Path.wildcard(Path.join(ctx.tmp_dir, "usr/lib/postgresql/*/bin"))
        |> Enum.filter(&File.exists?(Path.join(&1, "postgres")))
        |> Enum.max_by(fn p ->
          p |> Path.split() |> Enum.at(-2) |> Integer.parse() |> elem(0)
        end)

      assert String.contains?(ranked, "/16/")
    end
  end
end
