defmodule Mjolnir.Postgres.Supervisor do
  @moduledoc """
  Top-level supervisor for the Mjolnir Postgres sidecar.

  Children, in start order:
    1. `Mjolnir.Postgres.Server` — manages the postgres OS process via a Port
       and blocks in init until the socket is accepting connections.
    2. `Mjolnir.Postgres.Bootstrap` — creates roles, the `mjolnir` database,
       per-service schemas, and default privilege grants. Runs once on boot;
       idempotent.
    3. `Mjolnir.Postgres.Migrator` — applies pending Ecto migrations against
       the admin role; one-shot, exits :ok.
    4. `Mjolnir.Repo` — the long-running app repo (mjolnir_sites role).

  Started by `Mjolnir.Application` only when `:pg_enabled` is true. Default is
  true; `config/test.exs` sets it false so the unit-test suite stays fast.
  Tests that need a real Postgres bring up their own supervised instance with
  `start_supervised/1`.
  """

  use Supervisor
  require Logger

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Mjolnir.Postgres.Server,
      Mjolnir.Postgres.Bootstrap,
      Mjolnir.Postgres.Migrator,
      Mjolnir.Repo
    ]

    Logger.info("Postgres.Supervisor: starting")
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
