defmodule Mjolnir.Runner.ConfigWriter do
  @moduledoc """
  Generates and writes the YAML configuration file for the Forgejo runner.

  The runner binary reads this file at startup. We generate it from the
  resolved `Mjolnir.Runner.Config` struct using string interpolation — no
  external YAML library required.
  """

  require Logger

  alias Mjolnir.Runner.Config

  @doc """
  Write the runner YAML config to `config.config_path`.

  Creates `state_dir` and its subdirectories if they do not exist.
  Writes atomically via a temp file + rename.
  """
  @spec write_config(Config.t()) :: :ok | {:error, term()}
  def write_config(%Config{} = config) do
    with :ok <- File.mkdir_p(config.state_dir),
         :ok <- File.mkdir_p(Path.join(config.state_dir, "workspaces")),
         :ok <- ensure_config_dir(config.config_path) do
      content = render(config)
      write_atomic(config.config_path, content)
    end
  end

  ## Internal

  defp ensure_config_dir(config_path) do
    dir = Path.dirname(config_path)
    File.mkdir_p(dir)
  end

  defp render(%Config{} = config) do
    labels_yaml = format_labels(config.labels)

    """
    # Managed by Mjolnir.Runner.ConfigWriter — overwritten on every boot.
    log:
      level: #{config.log_level}
    runner:
      file: #{config.state_dir}/.runner
      capacity: #{config.max_concurrent_jobs}
      timeout: 3600
      insecure: false
      fetch_timeout: 5
      fetch_interval: 2
      labels: #{labels_yaml}
    cache:
      enabled: false
    host:
      workdir_parent: #{config.state_dir}/workspaces
    """
  end

  defp format_labels([]), do: "[]"

  defp format_labels(labels) do
    items = Enum.map_join(labels, ", ", fn l -> "\"#{l}\"" end)
    "[#{items}]"
  end

  defp write_atomic(path, content) do
    tmp = path <> ".tmp.#{:os.getpid()}"

    with :ok <- File.write(tmp, content) do
      case File.rename(tmp, path) do
        :ok ->
          :ok

        {:error, reason} ->
          _ = File.rm(tmp)
          {:error, reason}
      end
    end
  end
end
