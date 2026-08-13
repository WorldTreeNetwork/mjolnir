defmodule Mjolnir.Deploy.Detector do
  @moduledoc """
  Inspects an application directory and produces a `Mjolnir.Deploy.BuildPlan`.

  ## Two doors: declared, then inferred

  `detect/1` first looks for `mjolnir.toml` (`Mjolnir.Deploy.Manifest`). If the
  app declares itself, that declaration is used verbatim and no inference runs
  — an explicit statement always outranks a guess, even about a stack we would
  have recognised.

  Only if there is no manifest does framework inference run, and it recognises
  exactly one framework: SvelteKit/adapter-node, requiring both `package.json`
  and `svelte.config.js`. Anything else returns `{:error, :unsupported_app}`,
  whose remedy is a manifest rather than a new detector — we will never infer
  every stack, and an app that describes itself does not need us to.

  A manifest that exists but is malformed is an **error**, never a silent
  fallback to inference; see `Mjolnir.Deploy.Manifest`.

  Teaching inference more frameworks (generic Node, Python, Procfile) remains
  worthwhile as a convenience, but is no longer a prerequisite for deploying.

  ## Package manager detection

  The package manager is detected **from the lockfile**, never assumed. Defaulting
  to npm breaks bun/pnpm projects (field-validated against a bun + `bun.lock`
  SvelteKit app, 2026-06-23). Lockfiles are checked in this priority order:

  1. `bun.lock` or `bun.lockb` → `:bun`
  2. `pnpm-lock.yaml` → `:pnpm`
  3. `yarn.lock` → `:yarn`
  4. `package-lock.json` → `:npm`
  5. None of the above → `:npm` (default)

  The order is deterministic: bun > pnpm > yarn > npm. When multiple lockfiles
  are present (e.g. a committed `package-lock.json` alongside a `bun.lock`), the
  higher-priority lockfile wins.
  """

  alias Mjolnir.Deploy.{BuildPlan, Manifest}

  @runtime "node@20"
  @start_command "node build/index.js"
  @port 3000

  @doc """
  Inspects `app_dir` and returns its build plan.

  A `mjolnir.toml` manifest is honoured first and wins outright. Failing that,
  returns `{:ok, %BuildPlan{}}` for a recognised SvelteKit/adapter-node app, or
  `{:error, :unsupported_app}` if the required marker files are absent.

  A malformed manifest returns `{:error, {:invalid_manifest, message}}` — it
  does not degrade to inference.
  """
  @spec detect(app_dir :: String.t()) :: {:ok, BuildPlan.t()} | {:error, term()}
  def detect(app_dir) do
    case Manifest.load(app_dir) do
      {:ok, plan} -> {:ok, plan}
      {:error, _} = err -> err
      :none -> infer(app_dir)
    end
  end

  # Framework inference — reached only when the app did not declare itself.
  defp infer(app_dir) do
    with :ok <- require_file(app_dir, "package.json"),
         :ok <- require_file(app_dir, "svelte.config.js") do
      pm = detect_package_manager(app_dir)
      {:ok, build_plan(pm)}
    end
  end

  # Returns :ok if the file exists, {:error, :unsupported_app} otherwise.
  defp require_file(dir, name) do
    if File.exists?(Path.join(dir, name)) do
      :ok
    else
      {:error, :unsupported_app}
    end
  end

  # Checks lockfiles in deterministic priority order: bun > pnpm > yarn > npm.
  defp detect_package_manager(dir) do
    cond do
      File.exists?(Path.join(dir, "bun.lock")) -> :bun
      File.exists?(Path.join(dir, "bun.lockb")) -> :bun
      File.exists?(Path.join(dir, "pnpm-lock.yaml")) -> :pnpm
      File.exists?(Path.join(dir, "yarn.lock")) -> :yarn
      File.exists?(Path.join(dir, "package-lock.json")) -> :npm
      true -> :npm
    end
  end

  defp build_plan(pm) do
    %BuildPlan{
      runtime: @runtime,
      package_manager: pm,
      steps: ["mise install", install_step(pm), build_step(pm)],
      start_command: @start_command,
      port: @port
    }
  end

  defp install_step(:npm), do: "npm ci"
  defp install_step(:bun), do: "bun install"
  defp install_step(:pnpm), do: "pnpm install --frozen-lockfile"
  defp install_step(:yarn), do: "yarn install --frozen-lockfile"

  defp build_step(:npm), do: "npm run build"
  defp build_step(:bun), do: "bun run build"
  defp build_step(:pnpm), do: "pnpm run build"
  defp build_step(:yarn), do: "yarn build"
end
