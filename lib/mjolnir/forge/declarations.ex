defmodule Mjolnir.Forge.Declarations do
  @moduledoc """
  Loads `forge/declarations/*.exs`, evaluates each as an Elixir module using
  the `Mjolnir.Forge.Declaration` DSL, and exposes the result as a map of
  `host => [{kind_module, id, content}]`.

  v0: explicit reload only (`reload/0`). File watching is a v1 ticket.
  """

  use GenServer
  require Logger

  ## Public API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "List of `{kind_module, id, content}` declared for a host. `[]` if none."
  @spec for_host(String.t()) :: [{module(), String.t(), map()}]
  def for_host(host), do: GenServer.call(__MODULE__, {:for_host, host})

  @doc "Hosts that have at least one declaration."
  @spec hosts() :: [String.t()]
  def hosts, do: GenServer.call(__MODULE__, :hosts)

  @doc "Reload declarations from disk. Returns `:ok` or `{:error, reason}`."
  @spec reload() :: :ok | {:error, term()}
  def reload, do: GenServer.call(__MODULE__, :reload)

  @doc "Configured root directory (`config :mjolnir, :forge_declarations_path`)."
  @spec path() :: String.t()
  def path, do: Application.get_env(:mjolnir, :forge_declarations_path, "forge/declarations")

  @doc """
  Diff-engine input form: `%{ {kind_module, id} => content }` for a host.
  """
  @spec declared_map(String.t()) :: %{{module(), String.t()} => map()}
  def declared_map(host) do
    for {mod, id, content} <- for_host(host), into: %{}, do: {{mod, id}, content}
  end

  ## GenServer

  @impl true
  def init(_opts) do
    {:ok, load_safely()}
  end

  @impl true
  def handle_call({:for_host, host}, _from, state) do
    {:reply, Map.get(state, host, []), state}
  end

  def handle_call(:hosts, _from, state), do: {:reply, Map.keys(state), state}

  def handle_call(:reload, _from, _state) do
    {:reply, :ok, load_safely()}
  end

  ## Internals

  defp load_safely do
    try do
      load()
    rescue
      e ->
        Logger.error("Forge.Declarations load failed: #{Exception.format(:error, e, __STACKTRACE__)}")
        %{}
    end
  end

  defp load do
    dir = path()

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".exs"))
        |> Enum.flat_map(&load_file(Path.join(dir, &1)))
        |> Enum.group_by(
          fn {host, _kind, _id, _content} -> host end,
          fn {_host, kind, id, content} -> {kind, id, content} end
        )

      {:error, :enoent} ->
        Logger.info("Forge.Declarations: #{dir} does not exist (no declarations loaded)")
        %{}

      {:error, reason} ->
        Logger.error("Forge.Declarations could not list #{dir}: #{inspect(reason)}")
        %{}
    end
  end

  defp load_file(path) do
    try do
      [{mod, _bin} | _] = Code.compile_file(path)
      host = mod.__forge_host__()
      resources = mod.__forge_resources__()
      Enum.map(resources, fn {kind, id, content} -> {host, kind, id, content} end)
    rescue
      e ->
        Logger.error(
          "Forge.Declarations failed to load #{path}: " <>
            Exception.format(:error, e, __STACKTRACE__)
        )

        []
    end
  end
end
