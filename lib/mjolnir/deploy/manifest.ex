defmodule Mjolnir.Deploy.Manifest do
  @moduledoc """
  Reads `mjolnir.toml` — the explicit deploy manifest — into a `BuildPlan`.

  `Mjolnir.Deploy.Detector` *infers* a build plan by recognising a framework.
  That only ever works for stacks we taught it, and we will never teach it every
  stack. This module is the other door: an app describes itself, and Mjolnir
  runs what it is told.

      # mjolnir.toml
      runtime = "rust@1.83"
      steps = ["cargo build --release"]
      start_command = "./target/release/myapp"
      port = 8080

  ## Explicit beats inferred

  When `mjolnir.toml` is present it wins outright — detection is not consulted,
  even for an app we would have recognised.

  ## A broken manifest is an error, never a fallback

  A manifest that fails to parse or validate returns `{:error, …}`; it does
  **not** fall through to framework detection. Falling through would deploy a
  *different application* than the one the author described, and would do it
  silently — a typo'd `start_command` becoming "we ran the SvelteKit default
  instead" is the kind of failure that costs an afternoon. Unknown keys are
  errors for the same reason: `start-command` (hyphen) must not be accepted and
  ignored.

  ## Fields

  | key             | required | meaning                                          |
  |-----------------|----------|--------------------------------------------------|
  | `start_command` | yes      | command the service VM runs to start the app     |
  | `port`          | yes      | port the app binds inside the VM                 |
  | `steps`         | no       | ordered shell commands that build the app        |
  | `runtime`       | no       | mise runtime spec, e.g. `"rust@1.83"`            |

  When `runtime` is set and no step already invokes `mise`, a `mise install`
  step is prepended — otherwise `runtime` would be inert and the declared
  toolchain would never actually be installed.

  `package_manager` is deliberately absent: it exists to derive Node install
  commands and to pick a lockfile for cache keying, and a manifest app states
  its build steps outright. It is left `nil`, which
  `Orchestrator.plan_to_steps/3` already handles by hashing the whole source
  tree — the conservative choice.
  """

  alias Mjolnir.Deploy.BuildPlan

  @manifest_name "mjolnir.toml"

  @required_keys ~w(start_command port)
  @optional_keys ~w(steps runtime)
  @known_keys @required_keys ++ @optional_keys

  @doc "The manifest filename Mjolnir looks for (`#{@manifest_name}`)."
  @spec filename() :: String.t()
  def filename, do: @manifest_name

  @doc "Absolute path the manifest would occupy inside `app_dir`."
  @spec path(String.t()) :: String.t()
  def path(app_dir), do: Path.join(app_dir, @manifest_name)

  @doc "Is there a manifest in `app_dir`?"
  @spec present?(String.t()) :: boolean()
  def present?(app_dir), do: File.regular?(path(app_dir))

  @doc """
  Loads `app_dir/mjolnir.toml` into a `BuildPlan`.

  Returns `:none` when no manifest is present (the caller should fall back to
  detection), `{:ok, %BuildPlan{}}` on success, or `{:error, reason}` when a
  manifest exists but is unusable — which the caller must surface, not swallow.
  """
  @spec load(String.t()) :: {:ok, BuildPlan.t()} | {:error, term()} | :none
  def load(app_dir) do
    file = path(app_dir)

    if File.regular?(file) do
      with {:ok, raw} <- read(file),
           {:ok, map} <- parse(raw),
           {:ok, plan} <- to_plan(map) do
        {:ok, plan}
      end
    else
      :none
    end
  end

  # --- parsing ---------------------------------------------------------------

  defp read(file) do
    case File.read(file) do
      {:ok, raw} -> {:ok, raw}
      {:error, reason} -> {:error, {:manifest_unreadable, reason}}
    end
  end

  defp parse(raw) do
    case Toml.decode(raw) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _} ->
        {:error, {:invalid_manifest, "#{@manifest_name} must be a table of keys"}}

      {:error, reason} ->
        {:error, {:invalid_manifest, "#{@manifest_name} is not valid TOML: #{inspect(reason)}"}}
    end
  end

  # --- validation ------------------------------------------------------------

  defp to_plan(map) do
    with :ok <- reject_unknown_keys(map),
         {:ok, start_command} <- fetch_string(map, "start_command"),
         {:ok, port} <- fetch_port(map),
         {:ok, steps} <- fetch_steps(map),
         {:ok, runtime} <- fetch_optional_string(map, "runtime", "") do
      {:ok,
       %BuildPlan{
         runtime: runtime,
         package_manager: nil,
         steps: with_runtime_step(steps, runtime),
         start_command: start_command,
         port: port
       }}
    end
  end

  # A key we do not understand is a typo until proven otherwise. Accepting and
  # ignoring it means the author's intent silently does nothing.
  defp reject_unknown_keys(map) do
    case Map.keys(map) -- @known_keys do
      [] ->
        :ok

      unknown ->
        {:error,
         {:invalid_manifest,
          "unknown key(s) #{Enum.map_join(Enum.sort(unknown), ", ", &inspect/1)} — " <>
            "known keys are #{Enum.join(@known_keys, ", ")}"}}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, {:invalid_manifest, "#{key} must not be blank"}}
        else
          {:ok, value}
        end

      nil ->
        {:error, {:invalid_manifest, "#{key} is required"}}

      other ->
        {:error, {:invalid_manifest, "#{key} must be a string, got #{inspect(other)}"}}
    end
  end

  defp fetch_optional_string(map, key, default) do
    case Map.get(map, key) do
      nil -> {:ok, default}
      value when is_binary(value) -> {:ok, value}
      other -> {:error, {:invalid_manifest, "#{key} must be a string, got #{inspect(other)}"}}
    end
  end

  defp fetch_port(map) do
    case Map.get(map, "port") do
      port when is_integer(port) and port > 0 and port < 65_536 ->
        {:ok, port}

      nil ->
        {:error, {:invalid_manifest, "port is required"}}

      other ->
        {:error, {:invalid_manifest, "port must be an integer 1-65535, got #{inspect(other)}"}}
    end
  end

  defp fetch_steps(map) do
    case Map.get(map, "steps") do
      nil ->
        {:ok, []}

      steps when is_list(steps) ->
        if Enum.all?(steps, &is_binary/1) do
          {:ok, steps}
        else
          {:error, {:invalid_manifest, "steps must be a list of strings"}}
        end

      other ->
        {:error, {:invalid_manifest, "steps must be a list of strings, got #{inspect(other)}"}}
    end
  end

  # A declared runtime that nothing installs is a trap: the build would run
  # against whatever the base image happens to ship. Prepend the install unless
  # the author is already driving mise themselves.
  defp with_runtime_step(steps, ""), do: steps

  defp with_runtime_step(steps, _runtime) do
    if Enum.any?(steps, &String.starts_with?(&1, "mise")) do
      steps
    else
      ["mise install" | steps]
    end
  end
end
