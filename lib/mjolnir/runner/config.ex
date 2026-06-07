defmodule Mjolnir.Runner.Config do
  @moduledoc """
  Resolved configuration for the OTP-managed Forgejo runner.

  All values are read from `Application.get_env(:mjolnir, ...)` with sensible
  defaults. Environment variables can override the most critical fields at
  runtime.

  See `Mjolnir.Runner.Server` for usage.
  """

  @type t :: %__MODULE__{
          enabled: boolean(),
          binary_path: String.t(),
          config_path: String.t(),
          state_dir: String.t(),
          forgejo_url: String.t(),
          runner_name: String.t(),
          labels: [String.t()],
          max_concurrent_jobs: non_neg_integer(),
          log_level: String.t()
        }

  defstruct [
    :enabled,
    :binary_path,
    :config_path,
    :state_dir,
    :forgejo_url,
    :runner_name,
    :labels,
    :max_concurrent_jobs,
    :log_level
  ]

  @spec resolve() :: t()
  def resolve do
    enabled =
      case System.get_env("MJOLNIR_RUNNER_ENABLED") do
        nil -> get(:runner_enabled, false)
        "true" -> true
        "1" -> true
        _ -> false
      end

    binary_path =
      System.get_env("MJOLNIR_RUNNER_BINARY") ||
        get(:runner_binary_path, "/usr/local/bin/forgejo-runner-mjolnir")

    forgejo_url =
      System.get_env("MJOLNIR_RUNNER_FORGEJO_URL") ||
        get(:runner_forgejo_url, "http://127.0.0.1:3000")

    %__MODULE__{
      enabled: enabled,
      binary_path: binary_path,
      config_path: get(:runner_config_path, "/etc/mjolnir/runner.yml"),
      state_dir: get(:runner_state_dir, "/var/lib/mjolnir/runner"),
      forgejo_url: forgejo_url,
      runner_name: get(:runner_name, default_hostname()),
      labels: get(:runner_labels, ["ubuntu-24.04:host"]),
      max_concurrent_jobs: get(:runner_max_concurrent_jobs, 1),
      log_level: get(:runner_log_level, "info")
    }
  end

  defp get(key, default), do: Application.get_env(:mjolnir, key, default)

  defp default_hostname do
    case :inet.gethostname() do
      {:ok, hostname} -> List.to_string(hostname)
      _ -> "mjolnir-runner"
    end
  end
end
