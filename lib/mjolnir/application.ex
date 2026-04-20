defmodule Mjolnir.Application do
  @moduledoc """
  Mjolnir Orchestrator - MicroVM lifecycle management.

  Starts the supervision tree for VM management including:
  - VM Registry for process lookup
  - VM Supervisor for dynamic VM processes
  - HTTP API (Bandit) with JWT/OIDC authentication
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    api_port = Application.get_env(:mjolnir, :api_port, 4000)

    children =
      [
        # Durability: per-VM intent state, loaded into ETS before anything else runs
        Mjolnir.StateStore,

        # Synchronous sweep of orphaned hypervisor processes, stale sockets,
        # down TAPs, and unknown VM subvolumes. Uses Mjolnir.Startup.run so
        # the supervisor *blocks* until sweep completes, ensuring host-state
        # is clean before any VM children (or Reconcile) can race with it.
        %{
          id: Mjolnir.StartupCleanup,
          start: {Mjolnir.Startup, :run, [&Mjolnir.Cleanup.sweep/0]},
          restart: :temporary
        },

        # Registry for VM processes
        {Registry, keys: :unique, name: Mjolnir.VMRegistry},

        # Dynamic supervisor for VM processes
        {DynamicSupervisor, strategy: :one_for_one, name: Mjolnir.VMSupervisor},

        # Task supervisor for fire-and-forget operations (sub-agent spawn, snapshots)
        {Task.Supervisor, name: Mjolnir.TaskSupervisor},

        # Event bus for VM lifecycle events
        Mjolnir.EventBus,

        # Dormant VM registry for coroutine lifecycle
        Mjolnir.DormantRegistry,

        # Synchronous rehydration of running-intent VMs from StateStore. Must
        # run AFTER VMSupervisor/VMRegistry so VM GenServers can register,
        # AFTER DormantRegistry so resume flows don't race with dormant-wake,
        # and AFTER Mjolnir.Cleanup so stale TAPs/sockets are gone before
        # resume tries to recreate them.
        %{
          id: Mjolnir.StartupReconcile,
          start: {Mjolnir.Startup, :run, [&Mjolnir.Reconcile.run/0]},
          restart: :temporary
        }
      ] ++
        maybe_jwks_strategy() ++
        [
          # HTTP API
          {Bandit,
           plug: Mjolnir.API.Router,
           port: api_port,
           thousand_island_options: [read_timeout: :infinity]}
        ]

    opts = [strategy: :one_for_one, name: Mjolnir.Supervisor]

    Logger.info("Starting Mjolnir MicroVM Fabric")
    Logger.info("Starting Mjolnir Orchestrator (HTTP API on port #{api_port})")
    Supervisor.start_link(children, opts)
  end

  defp maybe_jwks_strategy do
    auth_config = Application.get_env(:mjolnir, :auth, [])

    if Keyword.get(auth_config, :issuer) do
      [{Mjolnir.Auth.KeycloakStrategy, issuer: auth_config[:issuer], first_fetch_sync: true}]
    else
      []
    end
  end
end
