defmodule Mjolnir.Forge.Resource.Sysctl do
  @moduledoc """
  Resource kind: a Linux kernel parameter managed via sysctl.

  Content shape: `%{value: binary()}`.

  ## Observe strategy

  This is a `:probe`-backed kind. The live kernel value is read via
  `sysctl -n <key>` rather than reading the config file on disk. This means
  drift detection catches runtime changes (e.g., a process flipped ip_forward
  back to 0) even if the file is correct.

  ## Persistence

  Apply writes `/etc/sysctl.d/99-forge-<key>.conf` with `<key> = <value>`,
  then activates immediately via `sysctl -w <key>=<value>`. The `99-` prefix
  ensures Forge-managed values win over distro defaults on reboot.

  ## Sandbox support

  When `config :mjolnir, :forge_sysctl_dir` is set to a non-default path,
  `sysctl -w` and `sysctl -n` are skipped (tests can't write kernel params).
  The conf file is still written for observation.
  """

  @behaviour Mjolnir.Forge.Resource

  @default_sysctl_dir "/etc/sysctl.d"

  def sysctl_dir, do: Application.get_env(:mjolnir, :forge_sysctl_dir, @default_sysctl_dir)

  @impl true
  def kind, do: "sysctl"

  @impl true
  def canonical(%{value: value}) when is_binary(value), do: String.trim(value)

  @impl true
  def observe_path(_id), do: :probe

  @impl true
  def parse_observed(bytes) when is_binary(bytes), do: %{value: String.trim(bytes)}

  @impl true
  def probe(_host, id) do
    if sysctl_active?() do
      case System.cmd("sysctl", ["-n", id], stderr_to_stdout: true) do
        {output, 0} -> {:ok, %{value: String.trim(output)}}
        {_, _} -> :missing
      end
    else
      # Sandbox: read from the conf file instead
      path = conf_path(id)

      case File.read(path) do
        {:ok, bytes} -> {:ok, parse_conf(bytes)}
        {:error, :enoent} -> :missing
        {:error, _} = err -> err
      end
    end
  end

  @impl true
  def apply(_host, id, %{value: value}) when is_binary(value) do
    dir = sysctl_dir()
    path = conf_path(id)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, "#{id} = #{value}\n") do
      if sysctl_active?() do
        case System.cmd("sysctl", ["-w", "#{id}=#{value}"], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {out, code} -> {:error, {:sysctl_write_failed, code, out}}
        end
      else
        :ok
      end
    end
  end

  @impl true
  def delete(_host, id) do
    path = conf_path(id)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def to_declaration(key, %{value: value}) do
    Mjolnir.Forge.Resource.render_block("sysctl", key, [{:value, inspect(value)}])
  end

  defp conf_path(id) do
    safe_name = String.replace(id, ".", "_")
    Path.join(sysctl_dir(), "99-forge-#{safe_name}.conf")
  end

  defp sysctl_active?, do: sysctl_dir() == @default_sysctl_dir

  defp parse_conf(bytes) do
    case Regex.run(~r/=\s*(.+)/, bytes) do
      [_, value] -> %{value: String.trim(value)}
      nil -> %{value: String.trim(bytes)}
    end
  end
end
