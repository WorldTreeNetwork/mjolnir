defmodule Mjolnir.Sites.Supervisor do
  @moduledoc """
  Top-level supervisor for the IdentiKey Sites subsystem (Phase 1: public mode).

  See `docs/plans/initiatives/identikey-sites.md` for the design.

  Children:
    * `Mjolnir.Sites.Store` — chunk store (BTRFS-backed, content-addressed)
    * `Mjolnir.Sites.Endpoints` — Iroh endpoint binder
    * `Mjolnir.Sites.TimestampUpgrader` — periodic OTS proof upgrader

  Depends on `Mjolnir.SecretStore` being started earlier in the application
  supervision tree (for reading HEAD records and per-site endpoint bindings).
  """

  use Supervisor
  require Logger

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Mjolnir.Sites.Store,
      Mjolnir.Sites.Endpoints,
      Mjolnir.Sites.TimestampUpgrader
    ]

    Logger.info("Sites.Supervisor: starting")
    Supervisor.init(children, strategy: :one_for_one)
  end
end
