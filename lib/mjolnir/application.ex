defmodule Mjolnir.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for VM processes
      {Registry, keys: :unique, name: Mjolnir.VMRegistry},

      # Dynamic supervisor for VM processes
      {DynamicSupervisor, strategy: :one_for_one, name: Mjolnir.VMSupervisor},

      # Debug server for remote control (localhost:9999)
      Mjolnir.DebugServer
    ]

    opts = [strategy: :one_for_one, name: Mjolnir.Supervisor]

    Logger.info("Starting Mjolnir MicroVM Fabric")
    Supervisor.start_link(children, opts)
  end
end
