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
        # Registry for VM processes
        {Registry, keys: :unique, name: Mjolnir.VMRegistry},

        # Dynamic supervisor for VM processes
        {DynamicSupervisor, strategy: :one_for_one, name: Mjolnir.VMSupervisor}
      ] ++
        maybe_jwks_strategy() ++
        [
          # HTTP API
          {Bandit, plug: Mjolnir.API.Router, port: api_port}
        ]

    opts = [strategy: :one_for_one, name: Mjolnir.Supervisor]

    Logger.info("Starting Mjolnir MicroVM Fabric")
    Mjolnir.Cleanup.sweep()
    Logger.info("Starting Mjolnir Orchestrator (HTTP API on port #{api_port})")
    Supervisor.start_link(children, opts)
  end

  defp maybe_jwks_strategy do
    auth_config = Application.get_env(:mjolnir, :auth, [])

    if Keyword.get(auth_config, :issuer) do
      [{Mjolnir.Auth.KeycloakStrategy, issuer: auth_config[:issuer]}]
    else
      []
    end
  end
end
