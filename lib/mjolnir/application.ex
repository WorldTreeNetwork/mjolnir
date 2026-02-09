defmodule Mjolnir.Application do
  @moduledoc """
  Mjolnir Orchestrator - MicroVM lifecycle management.

  Starts the supervision tree for VM management including:
  - VM Registry for process lookup
  - VM Supervisor for dynamic VM processes
  - Control Server for external TCP control (localhost:9999)
  """

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
      # Control server for external commands (localhost:9999)
      Mjolnir.ControlServer
    ]

    opts = [strategy: :one_for_one, name: Mjolnir.Supervisor]

    Logger.info("Starting Mjolnir MicroVM Fabric")
    Mjolnir.Cleanup.sweep()
    Logger.info("Starting Mjolnir Orchestrator")
    Supervisor.start_link(children, opts)
  end

  defp api_port do
    Application.get_env(:mjolnir, :api_port, 4000)
  end
end
