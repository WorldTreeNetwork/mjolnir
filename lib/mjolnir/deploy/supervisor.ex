defmodule Mjolnir.Deploy.Supervisor do
  @moduledoc """
  Supervises the `mj deploy` layer.

  For P0 the only long-lived child is `Mjolnir.Deploy.Registry` (the durable
  `app_name → release snapshot + service vm_id + url` store). `Deploy.Builder`
  and `Deploy.Runtime` are call-driven and own no processes, so they need no
  supervision. The `POST /api/deploy` orchestrator (gge.1.6) is likewise
  call-driven — `Mjolnir.Deploy.Orchestrator.deploy/3`, invoked directly from
  the HTTP handler — so it too owns no long-lived process here.

  Mounted under `Mjolnir.Supervisor` alongside `Forge.Supervisor` and
  `Sites.Supervisor`.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Mjolnir.Deploy.Registry
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
