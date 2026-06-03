defmodule Mjolnir.Forge.Supervisor do
  @moduledoc """
  Supervises the Forge subsystem:

      Mjolnir.Forge.Supervisor (one_for_one)
      ├── Mjolnir.Forge.Store           — JSON+ETS resource records
      ├── Mjolnir.Forge.EventBus         — :pg pub/sub for reconciliation events
      ├── Mjolnir.Forge.AuditLog         — append-only JSONL event log + replay
      ├── Mjolnir.Forge.Declarations     — loads forge/declarations/*.exs
      ├── Mjolnir.Forge.HostRegistry     — host_id → Host pid lookup
      └── Mjolnir.Forge.HostSupervisor   — DynamicSupervisor spawning Host workers

  Mounted under `Mjolnir.Supervisor`. Hosts are added via `start_host/1` once
  the supervisor is up.
  """

  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      Mjolnir.Forge.Store,
      Mjolnir.Forge.EventBus,
      Mjolnir.Forge.AuditLog,
      Mjolnir.Forge.Declarations,
      {Registry, keys: :unique, name: Mjolnir.Forge.HostRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Mjolnir.Forge.HostSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Spawn a `Mjolnir.Forge.Host` worker. Options:
    * `:host` — host identifier (e.g. `"self"`) — required
    * `:transport` — `:local` (default) or `:ssh`
    * `:auto_apply` — boolean, default `false`
  """
  @spec start_host(keyword()) :: DynamicSupervisor.on_start_child()
  def start_host(opts) do
    spec = %{
      id: {Mjolnir.Forge.Host, Keyword.fetch!(opts, :host)},
      start: {Mjolnir.Forge.Host, :start_link, [opts]},
      restart: :transient
    }

    DynamicSupervisor.start_child(Mjolnir.Forge.HostSupervisor, spec)
  end
end
