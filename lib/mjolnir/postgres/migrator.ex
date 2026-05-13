defmodule Mjolnir.Postgres.Migrator do
  @moduledoc """
  Runs Ecto migrations against the Mjolnir database. Started after
  `Mjolnir.Postgres.Bootstrap` has ensured the database, schemas, and grants
  exist.

  The migrator brings up `Mjolnir.Repo.Admin` (mjolnir_admin role), runs
  pending migrations, then stops the admin repo. App code uses
  `Mjolnir.Repo` (mjolnir_sites role), which lacks DDL privileges.

  Migrations live under `priv/repo/migrations/` and are evaluated lexically.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run pending migrations synchronously. Returns `:ok` on success or
  `{:error, reason}`. Safe to call in tests or from an iex shell.
  """
  @spec migrate() :: :ok | {:error, term()}
  def migrate do
    path = migrations_path()

    try do
      {:ok, _migrated, _apps} =
        Ecto.Migrator.with_repo(Mjolnir.Repo.Admin, fn repo ->
          Ecto.Migrator.run(repo, path, :up, all: true)
        end)

      :ok
    rescue
      e -> {:error, {:migration_failed, e, __STACKTRACE__}}
    end
  end

  @doc "Path to the migrations directory, resolved against the loaded app."
  @spec migrations_path() :: String.t()
  def migrations_path do
    case :code.priv_dir(:mjolnir) do
      {:error, _} -> Path.join([File.cwd!(), "priv", "repo", "migrations"])
      priv -> Path.join([to_string(priv), "repo", "migrations"])
    end
  end

  @impl true
  def init(_opts) do
    if Application.get_env(:mjolnir, :pg_managed, true) do
      case migrate() do
        :ok ->
          Logger.info("Postgres.Migrator: migrations applied")
          {:ok, %{}}

        {:error, reason} ->
          Logger.error("Postgres.Migrator: migration failed: #{inspect(reason)}")
          {:stop, reason}
      end
    else
      {:ok, %{}}
    end
  end
end
