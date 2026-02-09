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

      # HTTP API
      {Bandit, plug: Mjolnir.API.Router, port: api_port()}
    ]

    opts = [strategy: :one_for_one, name: Mjolnir.Supervisor]

    Logger.info("Starting Mjolnir MicroVM Fabric")
    Mjolnir.Cleanup.sweep()
    Supervisor.start_link(children, opts)
  end

  defp api_port do
    Application.get_env(:mjolnir, :api_port, 4000)
  end
end
