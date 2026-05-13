defmodule Mjolnir.Postgres.Config do
  @moduledoc """
  Resolved configuration for the OTP-managed Postgres sidecar.

  All paths and binaries are read from `Application.get_env(:mjolnir, ...)` with
  sensible defaults. The struct returned by `resolve/0` is used by
  `Mjolnir.Postgres.Server` and `Mjolnir.Postgres.Bootstrap` so the same view of
  the world drives initdb, conf writing, and Port spawn.
  """

  @type t :: %__MODULE__{
          managed: boolean(),
          data_dir: String.t(),
          socket_dir: String.t(),
          log_dir: String.t(),
          bin_dir: String.t(),
          postgres_bin: String.t(),
          initdb_bin: String.t(),
          pg_isready_bin: String.t(),
          psql_bin: String.t(),
          pg_ctl_bin: String.t(),
          run_as: String.t() | nil,
          bootstrap_role: String.t(),
          roles: [String.t()],
          ident_users: [String.t()],
          db_name: String.t(),
          socket_path: String.t()
        }

  defstruct [
    :managed,
    :data_dir,
    :socket_dir,
    :log_dir,
    :bin_dir,
    :postgres_bin,
    :initdb_bin,
    :pg_isready_bin,
    :psql_bin,
    :pg_ctl_bin,
    :run_as,
    :bootstrap_role,
    :roles,
    :ident_users,
    :db_name,
    :socket_path
  ]

  @spec resolve() :: t()
  def resolve do
    bin_dir = get(:pg_bin_dir, "/usr/bin")
    data_dir = get(:pg_data_dir, "/var/lib/mjolnir/pg")
    socket_dir = get(:pg_socket_dir, "/var/run/mjolnir")
    log_dir = get(:pg_log_dir, "/var/log/mjolnir/pg")
    bootstrap_role = get(:pg_bootstrap_role, "mjolnir_admin")
    roles = get(:pg_roles, ["mjolnir_admin", "mjolnir_sites"])
    current_user = current_os_user()

    ident_users =
      get(:pg_ident_users, [current_user])
      |> Enum.uniq()

    %__MODULE__{
      managed: get(:pg_managed, true),
      data_dir: data_dir,
      socket_dir: socket_dir,
      log_dir: log_dir,
      bin_dir: bin_dir,
      postgres_bin: Path.join(bin_dir, "postgres"),
      initdb_bin: Path.join(bin_dir, "initdb"),
      pg_isready_bin: Path.join(bin_dir, "pg_isready"),
      psql_bin: Path.join(bin_dir, "psql"),
      pg_ctl_bin: Path.join(bin_dir, "pg_ctl"),
      run_as: get(:pg_run_as, nil),
      bootstrap_role: bootstrap_role,
      roles: roles,
      ident_users: ident_users,
      db_name: get(:pg_database, "mjolnir"),
      socket_path: Path.join(socket_dir, ".s.PGSQL.5432")
    }
  end

  defp get(key, default), do: Application.get_env(:mjolnir, key, default)

  defp current_os_user do
    System.get_env("USER") || System.get_env("LOGNAME") || "mjolnir"
  end
end
