defmodule Mjolnir.Runner.Supervisor do
  @moduledoc """
  Top-level supervisor for the Mjolnir Forgejo runner.

  Children, in start order:
    1. `Mjolnir.Runner.Server` — manages the forgejo-runner OS process via a
       Port. If `runner_enabled` is false, the server starts but does nothing.

  Started by `Mjolnir.Application` only when `:runner_enabled` is true.
  """

  use Supervisor
  require Logger

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Mjolnir.Runner.Server
    ]

    Logger.info("Runner.Supervisor: starting")
    Supervisor.init(children, strategy: :one_for_one)
  end
end
