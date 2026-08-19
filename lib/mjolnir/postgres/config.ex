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
          socket_path: String.t(),
          tenant_listen_ip: String.t() | nil,
          tenants_file: String.t(),
          deploy_secrets_dir: String.t()
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
    :socket_path,
    :tenant_listen_ip,
    :tenants_file,
    :deploy_secrets_dir
  ]

  @doc """
  Locate the Postgres **server** binaries.

  The old compiled-in default was `/usr/bin`, which cannot work on the distro
  Mjolnir actually runs on in production. Debian and Ubuntu put `postgres` and
  `initdb` in `/usr/lib/postgresql/<version>/bin` and symlink only the *client*
  tools (`psql`, `pg_dump`) into `/usr/bin` — so the failure was a
  missing-binary error naming a path that was never plausible. It was correct
  on Arch, where pacman links everything into `/usr/bin`, which is why it
  survived local development.

  Production was unaffected because `/etc/mjolnir/env` sets
  `MJOLNIR_PG_BIN_DIR` (and since ae20e69 the host bootstrap writes it
  automatically). The default remained a trap for anyone running the release
  without a bootstrapped host: a manual install, a container, or a dev box.

  Resolution order:

  1. the highest-numbered `/usr/lib/postgresql/*/bin` that actually contains a
     `postgres` binary (Debian/Ubuntu)
  2. `/usr/bin` (Arch, Homebrew-linked, and anything that puts the server on
     PATH)

  Versions are compared numerically, so 9 sorts below 10 — a string sort picks
  `9` over `16` on a host carrying both, which is precisely the host where
  getting it wrong matters.

  An explicit `:pg_bin_dir` (or `MJOLNIR_PG_BIN_DIR`) always wins; this only
  fills in when nothing was configured.
  """
  @spec detect_bin_dir() :: String.t()
  def detect_bin_dir do
    case newest_versioned_bin_dir() do
      nil -> "/usr/bin"
      dir -> dir
    end
  end

  defp newest_versioned_bin_dir do
    "/usr/lib/postgresql/*/bin"
    |> Path.wildcard()
    # Require the server binary specifically. A version directory can exist
    # carrying only client tools (postgresql-client-16 installs one), and
    # picking it would reintroduce the same confusing missing-binary error at a
    # different path.
    |> Enum.filter(&File.exists?(Path.join(&1, "postgres")))
    |> Enum.max_by(&version_rank/1, fn -> nil end)
  end

  defp version_rank(path) do
    path
    |> Path.split()
    |> Enum.at(-2, "")
    |> Integer.parse()
    |> case do
      {n, _} -> n
      :error -> -1
    end
  end

  @spec resolve() :: t()
  def resolve do
    bin_dir = get(:pg_bin_dir, nil) || detect_bin_dir()
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
      socket_path: Path.join(socket_dir, ".s.PGSQL.5432"),
      tenant_listen_ip: blank_to_nil(get(:pg_tenant_listen_ip, nil)),
      tenants_file: get(:pg_tenants_file, "/var/lib/mjolnir/pg-tenants.json"),
      deploy_secrets_dir: get(:deploy_secrets_dir, "/var/lib/mjolnir/deploy/secrets")
    }
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s

  defp get(key, default), do: Application.get_env(:mjolnir, key, default)

  defp current_os_user do
    System.get_env("USER") || System.get_env("LOGNAME") || "mjolnir"
  end
end
