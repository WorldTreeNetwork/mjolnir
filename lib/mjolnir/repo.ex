defmodule Mjolnir.Repo do
  @moduledoc """
  Default Ecto repo for the Mjolnir application. Connects to the
  OTP-managed Postgres sidecar over a Unix socket as the `mjolnir_sites`
  service role.

  Connection parameters are resolved at process-start time from
  `Mjolnir.Postgres.Config`, not from static `config :mjolnir, Mjolnir.Repo`
  blocks, so the same code path works in dev (project-local data dir), test
  (per-test temporary dirs), and prod (`/var/lib/mjolnir/pg`).

  This repo only has perms on the `sites` schema — see
  `Mjolnir.Postgres.Bootstrap` for the grants. Cross-schema DDL must go
  through `Mjolnir.Repo.Admin`.
  """

  use Ecto.Repo,
    otp_app: :mjolnir,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_context, opts) do
    cfg = Mjolnir.Postgres.Config.resolve()

    runtime_opts = [
      socket_dir: cfg.socket_dir,
      username: "mjolnir_sites",
      database: cfg.db_name,
      pool_size: Application.get_env(:mjolnir, :pg_pool_size, 10),
      backoff_type: :stop
    ]

    {:ok, Keyword.merge(opts, runtime_opts)}
  end
end

defmodule Mjolnir.Repo.Admin do
  @moduledoc """
  Privileged Ecto repo used only for schema management and migrations. Logs
  in as the bootstrap role (`mjolnir_admin`), which owns every schema in the
  Mjolnir database and is the only role allowed to mutate them.

  This repo is **not** started in the supervision tree — it is brought up on
  demand by `Mjolnir.Postgres.Migrator` and torn down when migrations
  complete. App code should never call `Mjolnir.Repo.Admin.*`.
  """

  use Ecto.Repo,
    otp_app: :mjolnir,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_context, opts) do
    cfg = Mjolnir.Postgres.Config.resolve()

    runtime_opts = [
      socket_dir: cfg.socket_dir,
      username: cfg.bootstrap_role,
      database: cfg.db_name,
      pool_size: 2,
      backoff_type: :stop
    ]

    {:ok, Keyword.merge(opts, runtime_opts)}
  end
end
