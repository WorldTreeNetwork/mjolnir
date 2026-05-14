defmodule Mjolnir.Sites.Endpoints do
  @moduledoc """
  Iroh endpoint binder for the sites server.

  On startup, walks the SecretStore for all registered site endpoint records
  and binds an Iroh endpoint per `(identikey_fp, site_name)`. Each endpoint
  reads its associated HEAD on dial and serves the resulting snapshot.

  See `docs/plans/initiatives/identikey-sites.md` §9.

  Phase 1: this module exists as a scaffold and tracks intended bindings in
  memory. Actual Iroh endpoint binding is deferred until the transport plumbing
  is connected (will reuse the same code path as VM Iroh endpoints).
  """

  use GenServer
  require Logger

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register an intent to bind an Iroh endpoint for a given site. Returns the
  generated (or already-bound) endpoint identity.

  TODO Phase 1: actually bind via the Iroh transport once exposed from the
  Rust side. For now this just records the intent.
  """
  @spec bind(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def bind(identikey_fp, site_name) do
    GenServer.call(__MODULE__, {:bind, identikey_fp, site_name})
  end

  @doc "List currently-tracked endpoint bindings."
  @spec list() :: [map()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  ## GenServer

  @impl true
  def init(_opts) do
    Logger.info("Sites.Endpoints: starting (Phase 1 scaffold — binding deferred)")
    {:ok, %{bindings: %{}}}
  end

  @impl true
  def handle_call({:bind, fp, name}, _from, state) do
    key = {fp, name}

    case Map.get(state.bindings, key) do
      nil ->
        binding = %{identikey_fp: fp, site_name: name, bound_at: DateTime.utc_now()}
        Logger.info("Sites.Endpoints: bind intent recorded for #{fp}/#{name}")
        {:reply, {:ok, binding}, %{state | bindings: Map.put(state.bindings, key, binding)}}

      existing ->
        {:reply, {:ok, existing}, state}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.bindings), state}
  end
end
