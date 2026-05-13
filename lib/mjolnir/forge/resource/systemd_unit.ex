defmodule Mjolnir.Forge.Resource.SystemdUnit do
  @moduledoc """
  Resource kind: a systemd unit file under `/etc/systemd/system/<id>`.

  Content shape: `%{source: binary(), enabled: boolean(), state: :running | :stopped}`.

  v0 drift semantics: only the file contents are diffed. `enabled` and `state`
  are apply-time intentions (the unit is enabled/started on apply) but are
  not probed for drift — a v1 ticket adds `systemctl is-enabled` and
  `is-active` checks. This keeps the core loop file-backed and fast.
  """

  @behaviour Mjolnir.Forge.Resource

  @default_units_dir "/etc/systemd/system"

  @doc """
  Root directory for systemd unit files. Defaults to `/etc/systemd/system`;
  override with `config :mjolnir, :forge_systemd_units_dir, "/tmp/..."` (used
  by tests so they don't write into the real systemd directory).
  """
  def units_dir, do: Application.get_env(:mjolnir, :forge_systemd_units_dir, @default_units_dir)

  @impl true
  def kind, do: "systemd_unit"

  @impl true
  def canonical(%{source: source}) when is_binary(source), do: source

  @impl true
  def observe_path(id), do: {:file, Path.join(units_dir(), id)}

  @impl true
  def parse_observed(bytes) when is_binary(bytes) do
    %{source: bytes, enabled: nil, state: nil}
  end

  @impl true
  def probe(_host, _id), do: {:error, :file_backed_kind}

  @impl true
  def apply(_host, id, %{source: src} = content) when is_binary(src) do
    dir = units_dir()
    path = Path.join(dir, id)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, src) do
      if systemctl_active?() do
        with {_, 0} <- run(["systemctl", "daemon-reload"]),
             :ok <- maybe_enable(id, Map.get(content, :enabled, true)),
             :ok <- maybe_start(id, Map.get(content, :state, :running)) do
          :ok
        else
          {_, code} when is_integer(code) -> {:error, {:systemctl_failed, code}}
          {:error, _} = err -> err
        end
      else
        # Sandbox mode (test/dry-run): the file is written but no systemd
        # side effects are performed. Diff/observation works normally.
        :ok
      end
    end
  end

  @impl true
  def delete(_host, id) do
    dir = units_dir()
    path = Path.join(dir, id)

    if systemctl_active?(), do: _ = run(["systemctl", "disable", "--now", id])

    result =
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _} = err -> err
      end

    if systemctl_active?() and result == :ok, do: reload_daemon(), else: result
  end

  defp systemctl_active?, do: units_dir() == @default_units_dir

  defp maybe_enable(_id, false), do: :ok

  defp maybe_enable(id, _true_or_nil) do
    case run(["systemctl", "enable", id]) do
      {_, 0} -> :ok
      {_, code} -> {:error, {:enable_failed, code}}
    end
  end

  defp maybe_start(_id, :stopped), do: :ok

  defp maybe_start(id, _running_or_nil) do
    case run(["systemctl", "restart", id]) do
      {_, 0} -> :ok
      {_, code} -> {:error, {:restart_failed, code}}
    end
  end

  defp reload_daemon do
    case run(["systemctl", "daemon-reload"]) do
      {_, 0} -> :ok
      {_, code} -> {:error, {:daemon_reload_failed, code}}
    end
  end

  defp run([cmd | args]) do
    System.cmd(cmd, args, stderr_to_stdout: true)
  end
end
