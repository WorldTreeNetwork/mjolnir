defmodule Mjolnir.Syslog.Supervisor do
  @moduledoc """
  Supervises the Syslog subsystem:

      Mjolnir.Syslog.Supervisor (one_for_one)
      ├── Mjolnir.Syslog.Router    — routes messages to configured sinks
      └── Mjolnir.Syslog.Listener  — vsock ch2 + optional host UDP ingest

  Mounted under `Mjolnir.Application` when `:syslog_enabled` is `true`
  (the default). Disable via:

      config :mjolnir, syslog_enabled: false
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Mjolnir.Syslog.Router,
      Mjolnir.Syslog.Listener
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
