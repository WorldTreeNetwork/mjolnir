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

  A manifest that fails to parse or whose *known* required fields are missing
  or mistyped returns `{:error, …}`; it does **not** fall through to framework
  detection. Falling through would deploy a *different application* than the
  one the author described — a missing `start_command` becoming "we ran the
  SvelteKit default instead" is the kind of failure that costs an afternoon.

  Unknown keys and tables are ignored (HTTP-style: parse what we understand).
  A newer `mjolnir.toml` with `[site]` or a future key must still load on an
  older `mj`. A hyphenated typo (`start-command`) is then a missing
  `start_command`, which still errors — the required-field check is the
  safety net, not a closed key set.

  ## Spawn targets

  Top-level keys are the **prod** plan (`mj deploy`). `[targets.<name>]`
  is a long-lived VM selected by `mj spawn --target <name>`. `load/1`
  ignores `[targets]`. `load_target/2` reads one name and errors when
  that table is missing or unusable. A bad target does not change what
  `mj deploy` builds.

      [targets.dev]
      snapshot = "hosted-devpreview-test"
      base = "ubuntu-24.04"
      memory_mb = 2048
      port = 80
      workdir = "/root/app"
      command = "bun run dev --host 0.0.0.0 --port 80"
      preserve_iroh_key = true

      [targets.dev.env]
      VITE_MEDUSA_BACKEND_URL = "https://api.hypersigil.world"

      [targets.dev.git]
      remote = "forgejo"
      sign = true

  `snapshot` is a cache of that spec. When both `snapshot` and `base` are
  set, spawn uses the snapshot. `sign = true` asks the host to mint a
  git-signing key for the new VM. Secrets do not belong in this file.

  ## Fields

  | key             | required | meaning                                          |
  |-----------------|----------|--------------------------------------------------|
  | `start_command` | yes      | command the service VM runs to start the app     |
  | `port`          | yes      | port the app binds inside the VM                 |
  | `steps`         | no       | ordered string or `{ run, inputs }` build steps  |
  | `runtime`       | no       | mise runtime spec, e.g. `"rust@1.83"`            |
  | `base_image`    | no       | `@base/` name, e.g. `"ubuntu-24.04"` (6ee1)     |

  String steps retain the conservative behavior: the whole source tree keys
  the layer and is copied into `/app`. A table step declares the source globs
  it reads. For example, identikey can keep package installation independent
  of source edits while scoping the web build to its own tree:

      steps = [
        { run = "apt-get install -y build-essential", inputs = [] },
        { run = "cd web && npm run build", inputs = ["web/**"] }
      ]

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

  defmodule DevTarget do
    @moduledoc "One `[targets.<name>]` table: a long-lived VM, not a prod cutover."
    @enforce_keys [:command, :port, :memory_mb, :preserve_iroh_key, :git_sign, :env]
    defstruct [
      :base,
      :snapshot,
      :command,
      :workdir,
      :git_remote,
      :port,
      :memory_mb,
      :preserve_iroh_key,
      :git_sign,
      :env
    ]

    @type t :: %__MODULE__{
            base: String.t() | nil,
            snapshot: String.t() | nil,
            command: String.t(),
            workdir: String.t() | nil,
            git_remote: String.t() | nil,
            port: pos_integer(),
            memory_mb: pos_integer(),
            preserve_iroh_key: boolean(),
            git_sign: boolean(),
            env: %{optional(String.t()) => String.t()}
          }
  end

  @manifest_name "mjolnir.toml"

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
  @doc """
  Loads `[targets.<name>]`. `:none` when the file or that target is absent.
  `{:error, _}` when the target is present but unusable.
  """
  @spec load_target(String.t(), String.t()) :: {:ok, DevTarget.t()} | {:error, term()} | :none
  def load_target(app_dir, name) when is_binary(name) and name != "" do
    file = path(app_dir)

    if File.regular?(file) do
      with {:ok, raw} <- read(file),
           {:ok, map} <- parse(raw) do
        case Map.get(map, "targets") do
          nil ->
            :none

          targets when is_map(targets) ->
            case Map.get(targets, name) do
              nil ->
                :none

              spec when is_map(spec) ->
                to_target(name, spec)

              other ->
                {:error,
                 {:invalid_manifest, "[targets.#{name}] must be a table, got #{inspect(other)}"}}
            end

          other ->
            {:error, {:invalid_manifest, "[targets] must be a table, got #{inspect(other)}"}}
        end
      end
    else
      :none
    end
  end

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
    with {:ok, start_command} <- fetch_string(map, "start_command"),
         {:ok, port} <- fetch_port(map),
         {:ok, steps} <- fetch_steps(map),
         {:ok, runtime} <- fetch_optional_string(map, "runtime", ""),
         {:ok, base_image} <- fetch_optional_name(map, "base_image") do
      {:ok,
       %BuildPlan{
         runtime: runtime,
         package_manager: nil,
         steps: with_runtime_step(steps, runtime),
         start_command: start_command,
         port: port,
         base_image: base_image
       }}
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
      "" -> {:ok, default}
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
        steps
        |> Enum.with_index(1)
        |> Enum.reduce_while({:ok, []}, fn {step, index}, {:ok, acc} ->
          case validate_step(step, index) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
          error -> error
        end

      other ->
        {:error,
         {:invalid_manifest,
          "steps must be a list of strings or {run, inputs} tables, got #{inspect(other)}"}}
    end
  end

  defp validate_step(step, _index) when is_binary(step), do: {:ok, step}

  defp validate_step(step, index) when is_map(step) do
    allowed = MapSet.new(["run", "inputs"])

    case Enum.find(Map.keys(step), &(not MapSet.member?(allowed, &1))) do
      nil -> validate_step_fields(step, index)
      bad_key -> invalid_step(index, "unknown key #{inspect(bad_key)}")
    end
  end

  defp validate_step(step, index),
    do: invalid_step(index, "must be a string or a {run, inputs} table, got #{inspect(step)}")

  defp validate_step_fields(step, index) do
    run = Map.get(step, "run")
    inputs = Map.get(step, "inputs")

    cond do
      not is_binary(run) or String.trim(run) == "" ->
        invalid_step(index, "key \"run\" must be a non-blank string")

      not is_list(inputs) or not Enum.all?(inputs, &is_binary/1) ->
        invalid_step(index, "key \"inputs\" must be a list of strings")

      Enum.any?(inputs, &(Path.type(&1) == :absolute or invalid_relative_glob?(&1))) ->
        invalid_step(index, "key \"inputs\" must contain globs relative to the source root")

      true ->
        {:ok, %{run: run, inputs: inputs}}
    end
  end

  defp invalid_relative_glob?(glob) do
    glob == "" or glob |> Path.split() |> Enum.any?(&(&1 == ".."))
  end

  defp invalid_step(index, detail),
    do: {:error, {:invalid_manifest, "step #{index} #{detail}"}}

  # A declared runtime that nothing installs is a trap: the build would run
  # against whatever the base image happens to ship. Prepend the install unless
  # the author is already driving mise themselves.
  defp to_target(name, dev) do
    with {:ok, command} <- fetch_string(dev, "command"),
         {:ok, port} <- fetch_dev_port(dev),
         {:ok, memory_mb} <- fetch_memory(dev),
         {:ok, base} <- fetch_optional_name(dev, "base"),
         {:ok, snapshot} <- fetch_optional_name(dev, "snapshot"),
         {:ok, workdir} <- fetch_optional_string(dev, "workdir", nil),
         {:ok, preserve} <- fetch_bool(dev, "preserve_iroh_key", snapshot != nil),
         {:ok, env} <- fetch_env(dev),
         {:ok, git_remote, git_sign} <- fetch_git(dev) do
      if base == nil and snapshot == nil do
        {:error, {:invalid_manifest, "[targets.#{name}] needs base or snapshot"}}
      else
        {:ok,
         %DevTarget{
           base: base,
           snapshot: snapshot,
           command: command,
           workdir: workdir,
           git_remote: git_remote,
           port: port,
           memory_mb: memory_mb,
           preserve_iroh_key: preserve,
           git_sign: git_sign,
           env: env
         }}
      end
    end
  end

  defp fetch_optional_name(map, key) do
    case Map.get(map, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" or String.contains?(trimmed, ["/", "..", " "]) do
          {:error, {:invalid_manifest, "#{key} must be a single path segment"}}
        else
          {:ok, trimmed}
        end

      other ->
        {:error, {:invalid_manifest, "#{key} must be a string, got #{inspect(other)}"}}
    end
  end

  defp fetch_memory(map) do
    case Map.get(map, "memory_mb") do
      nil ->
        {:ok, 2048}

      n when is_integer(n) and n >= 128 and n <= 32_768 ->
        {:ok, n}

      other ->
        {:error,
         {:invalid_manifest, "memory_mb must be an integer 128-32768, got #{inspect(other)}"}}
    end
  end

  defp fetch_bool(map, key, default) do
    case Map.get(map, key) do
      nil -> {:ok, default}
      value when is_boolean(value) -> {:ok, value}
      other -> {:error, {:invalid_manifest, "#{key} must be a boolean, got #{inspect(other)}"}}
    end
  end

  defp fetch_env(dev) do
    case Map.get(dev, "env") do
      nil ->
        {:ok, %{}}

      env when is_map(env) ->
        Enum.reduce_while(env, {:ok, %{}}, fn
          {k, v}, {:ok, acc} when is_binary(k) and is_binary(v) ->
            if String.contains?(v, ["\n", "\r"]) do
              {:halt, {:error, {:invalid_manifest, "dev.env #{k} must be a single line"}}}
            else
              {:cont, {:ok, Map.put(acc, k, v)}}
            end

          {k, v}, _ ->
            {:halt,
             {:error, {:invalid_manifest, "dev.env #{k} must be a string, got #{inspect(v)}"}}}
        end)

      other ->
        {:error, {:invalid_manifest, "[targets.env] must be a table, got #{inspect(other)}"}}
    end
  end

  defp fetch_git(dev) do
    case Map.get(dev, "git") do
      nil ->
        {:ok, nil, false}

      git when is_map(git) ->
        with {:ok, remote} <- fetch_optional_string(git, "remote", nil),
             {:ok, sign} <- fetch_bool(git, "sign", false) do
          {:ok, remote, sign}
        end

      other ->
        {:error, {:invalid_manifest, "[targets.git] must be a table, got #{inspect(other)}"}}
    end
  end

  defp fetch_dev_port(map) do
    case Map.get(map, "port") do
      nil ->
        {:ok, 80}

      port when is_integer(port) and port > 0 and port < 65_536 ->
        {:ok, port}

      other ->
        {:error, {:invalid_manifest, "port must be an integer 1-65535, got #{inspect(other)}"}}
    end
  end

  defp with_runtime_step(steps, ""), do: steps

  defp with_runtime_step(steps, _runtime) do
    if Enum.any?(steps, &(step_command(&1) |> String.starts_with?("mise"))) do
      steps
    else
      ["mise install" | steps]
    end
  end

  defp step_command(step) when is_binary(step), do: step
  defp step_command(%{run: run}), do: run
end
