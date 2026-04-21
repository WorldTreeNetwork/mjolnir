defmodule Mjolnir.Health.Check do
  @moduledoc """
  Behaviour for per-VM and host-wide health checks.

  Every check has:
  - a **level** (0–5 for VM checks, `:host` for host-wide) — the escalation
    tier. Lower = cheaper, closer to "just observe"; higher = closer to
    "destroy and rebuild".
  - a **name** — short identifier used in reports and logs.
  - a **probe** — read-only. Must *exercise* the dependency end-to-end
    (send a byte, get a byte back), not just check that something exists.
    Returns `:ok | {:degraded, reason} | {:dead, reason}`.
  - a **heal** — idempotent destroy-then-create. Safe to call regardless
    of current state. Returns `:ok | {:error, reason}`.

  ## Status semantics

  - `:ok` — probe round-tripped cleanly. Dependency is working.
  - `{:degraded, reason}` — probe got a response but it indicated a soft
    problem (high latency, partial answer, stale info). Heal may be worth
    trying.
  - `{:dead, reason}` — probe failed entirely (timeout, connection refused,
    syscall error). Heal is needed.
  """

  @type status :: :ok | {:degraded, any()} | {:dead, any()}
  @type level :: 0..5 | :host

  @callback level() :: level()
  @callback name() :: String.t()
  @callback probe(target :: any()) :: status()
  @callback heal(target :: any()) :: :ok | {:error, any()}
end
