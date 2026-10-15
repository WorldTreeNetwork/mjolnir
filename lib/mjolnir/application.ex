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

        # Signed-record key-value store for IdentiKey-rooted mutable state
        # (site HEAD pointers, endpoint bindings, etc.). Starts early so it is
        # available before Sites.Supervisor reads HEAD records.
        Mjolnir.SecretStore
      ] ++
        maybe_postgres_children() ++
        [
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

          # Per-actor durable message spool (ADR 0006)
          Mjolnir.Mailbox,

          # Buzz protocol facade: Nostr (later Matrix) → OTP mailbox → last hop
          # is a conformant Nostr event for buzz-acp. Named wake producer. The
          # host is not a second event log.
          Mjolnir.Buzz.Facade,
          %{
            id: Mjolnir.StartupMailboxSweep,
            start: {Task, :start_link, [&Mjolnir.Mailbox.sweep/0]},
            restart: :temporary
          },

          # Asynchronous rehydration of running-intent VMs from StateStore.
          # Spawned as a concurrent Task — NOT a blocking Mjolnir.Startup phase
          # — so the HTTP API (Bandit, below) becomes available immediately,
          # independent of how many VMs must resume (mjolnir-s8h: a blocking
          # sequential resume of N stranded VMs delayed the API by ~N×3s).
          #
          # Ordering guarantees still hold because this is a *later sibling*:
          # the supervisor only reaches it AFTER Mjolnir.Cleanup's blocking
          # sweep removed stale TAPs/sockets, and AFTER VMSupervisor/VMRegistry
          # (so VM GenServers can register) and DormantRegistry (so resume does
          # not race dormant-wake) are up. Only the Task *body* runs concurrently
          # with Bandit — and that is the goal. Stranded :running records surface
          # in /api/vms as state=recovering until each VM re-registers, so the
          # API stays honest while rehydration proceeds. Reconcile.run/0 resumes
          # with bounded concurrency, and Health.Monitor re-runs it every 30s as
          # a safety net if this initial pass misses any.
          %{
            id: Mjolnir.StartupReconcile,
            start: {Task, :start_link, [&Mjolnir.Reconcile.run/0]},
            restart: :temporary
          },

          # Periodic health monitor — every 30s, probe all registered VMs and
          # auto-heal L1 degradations (Iroh rot, vsock drift) before a user-
          # facing request exposes them. Emits EventBus events on :dead.
          Mjolnir.Health.Monitor,

          # Forge: host config reconciler. See docs/plans/host-reconcile.md.
          Mjolnir.Forge.Supervisor,

          # IdentiKey static sites — content-addressed chunk store, Iroh endpoint
          # binding, OpenTimestamps proof upgrader. See
          # docs/plans/initiatives/identikey-sites.md.
          Mjolnir.Sites.Supervisor,

          # mj deploy layer — durable per-app deployment registry (the Builder
          # and Runtime are call-driven). See
          # docs/plans/initiatives/mjolnir-deploy.md.
          Mjolnir.Deploy.Supervisor
        ] ++
        maybe_gateway_routes_children() ++
        maybe_syslog_children() ++
        maybe_runner_children() ++
        maybe_jwks_strategy() ++
        [
          # In-flight browser logins against IdentiKey Connect (mjolnir-wrug.3)
          Mjolnir.Auth.Login,

          # Single-use nonces for holder-bound secret redeem.
          Mjolnir.Secrets.Nonces,

          # HTTP API. TCP. A loopback peer is not the operator.
          {Bandit,
           plug: Mjolnir.API.Router,
           port: api_port,
           thousand_island_options: [read_timeout: :infinity]}
        ] ++
        operator_listener()

    opts = [strategy: :one_for_one, name: Mjolnir.Supervisor]

    Logger.info("Starting Mjolnir MicroVM Fabric")
    Logger.info("Starting Mjolnir Orchestrator (HTTP API on port #{api_port})")

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      chmod_operator_socket()
      maybe_isolate_guests()
      {:ok, pid}
    end
  end

  defp operator_listener do
    case Application.get_env(:mjolnir, :operator_socket) do
      path when is_binary(path) and path != "" ->
        File.rm(path)
        File.mkdir_p!(Path.dirname(path))

        [
          {Bandit,
           plug: Mjolnir.API.OperatorPipeline,
           scheme: :http,
           port: 0,
           ip: {:local, path},
           thousand_island_options: [read_timeout: :infinity]}
        ]

      _ ->
        []
    end
  end

  defp chmod_operator_socket do
    case Application.get_env(:mjolnir, :operator_socket) do
      path when is_binary(path) -> File.chmod(path, 0o600)
      _ -> :ok
    end
  end

  defp maybe_isolate_guests do
    if Application.get_env(:mjolnir, :isolate_guests, false) do
      case Mjolnir.Network.ensure_guest_isolation() do
        :ok -> :ok
        {:error, reason} -> Logger.warning("guest isolation: #{inspect(reason)}")
      end
    end
  end

  defp maybe_jwks_strategy do
    auth_config = Application.get_env(:mjolnir, :auth, [])

    # The issuer (auth.identikey.me) is served by a VM on this host. A
    # synchronous fetch during boot waits on a guest that this same boot is
    # supposed to resume, times out, and used to take the whole release down
    # before Bandit listened. Fetch in the background; verification fails
    # closed until the first successful refresh.
    if Keyword.get(auth_config, :issuer) do
      [{Mjolnir.Auth.JwksStrategy, issuer: auth_config[:issuer], first_fetch_sync: false}]
    else
      []
    end
  end

  defp maybe_postgres_children do
    if Application.get_env(:mjolnir, :pg_enabled, false) do
      [Mjolnir.Postgres.Supervisor]
    else
      []
    end
  end

  defp maybe_syslog_children do
    syslog_config = Application.get_env(:mjolnir, :syslog, [])

    if Keyword.get(syslog_config, :enabled, true) do
      [Mjolnir.Syslog.Supervisor]
    else
      []
    end
  end

  defp maybe_runner_children do
    if Application.get_env(:mjolnir, :runner_enabled, false) do
      [Mjolnir.Runner.Supervisor]
    else
      []
    end
  end

  # Gateway local-route reconciler. Renders /etc/mjolnir/gateway.d/apps.toml from
  # live VM + Deploy.Registry state so co-located VMs are served over direct TCP.
  # Off by default (writes to /etc + shells out to systemctl) so `mix test` and
  # dev machines stay green; prod flips it on. See docs/plans/gateway-local-routing.md.
  defp maybe_gateway_routes_children do
    if Application.get_env(:mjolnir, :gateway_routes_enabled, false) do
      [Mjolnir.Gateway.RouteReconciler]
    else
      []
    end
  end
end
