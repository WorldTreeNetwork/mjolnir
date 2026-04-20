defmodule Mjolnir.Startup do
  @moduledoc """
  Helpers for synchronous, ordered initialization phases under a Supervisor.

  ## Why this exists

  `{Task, fn -> ... end}` as a Supervisor child runs *concurrently* with its
  siblings — `Task.start_link` returns `{:ok, pid}` as soon as the task is
  spawned, not when its body completes. That makes Tasks the wrong primitive
  for boot-time work that MUST finish before the next supervision phase
  starts (e.g. `Mjolnir.Cleanup.sweep/0` must run to completion before
  `Mjolnir.Reconcile.run/0` tries to recreate TAPs that `Cleanup` is still
  deleting).

  `Mjolnir.Startup.run/1` is called by the supervisor as a "start function"
  that does its work inline and returns `:ignore`. Supervisor start is
  synchronous on the start-function return, so this *blocks* the supervisor
  until the work finishes — giving us ordered phases.
  """

  require Logger

  @doc """
  Runs `fun` synchronously and returns `:ignore` so the Supervisor treats
  this child as "successfully skipped" and moves on to the next child.
  """
  @spec run((-> any())) :: :ignore
  def run(fun) when is_function(fun, 0) do
    try do
      fun.()
    rescue
      e ->
        Logger.error("Mjolnir.Startup phase raised: #{inspect(e)}")
    catch
      kind, reason ->
        Logger.error("Mjolnir.Startup phase threw #{kind}: #{inspect(reason)}")
    end

    :ignore
  end
end
