defmodule Mjolnir.Forge.Resource.AptPackage do
  @moduledoc """
  Resource kind: a Debian/Ubuntu package managed via apt.

  Content shape: `%{state: :installed | :removed | :held, version: binary() | nil}`.

  ## Observe strategy

  Probe-backed via `dpkg-query -W -f='${db:Status-Status} ${Version}' <pkg>`.
  Returns the installed version or `:missing` if the package isn't installed.

  ## Apply semantics

  - `:installed` — `apt-get install -y <pkg>` (or `<pkg>=<version>` if pinned)
  - `:held` — install if needed, then `apt-mark hold <pkg>`
  - `:removed` — `apt-get remove -y <pkg>`

  ## Sandbox support

  When `config :mjolnir, :forge_apt_sandbox` is `true`, all apt/dpkg commands
  are stubbed and the module uses an in-memory registry (ETS) to simulate
  package state. This allows tests to run without root or apt.
  """

  @behaviour Mjolnir.Forge.Resource

  @impl true
  def kind, do: "apt_package"

  @impl true
  def canonical(%{state: state} = content) when state in [:installed, :removed, :held] do
    version = Map.get(content, :version)

    if version do
      "#{state}:#{version}"
    else
      "#{state}"
    end
  end

  @impl true
  def observe_path(_id), do: :probe

  @impl true
  def parse_observed(bytes) when is_binary(bytes) do
    case String.split(String.trim(bytes), " ", parts: 2) do
      ["installed", version] -> %{state: :installed, version: version}
      ["hold", version] -> %{state: :held, version: version}
      _ -> %{state: :removed, version: nil}
    end
  end

  @impl true
  def probe(_host, id) do
    if sandbox?() do
      probe_sandbox(id)
    else
      case System.cmd("dpkg-query", ["-W", "-f=${db:Status-Status} ${Version}", id],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          content = parse_observed(output)

          if content.state == :removed do
            :missing
          else
            {:ok, content}
          end

        {_, _} ->
          :missing
      end
    end
  end

  @impl true
  def apply(_host, id, %{state: state} = content) do
    if sandbox?() do
      apply_sandbox(id, content)
    else
      case state do
        :installed -> install(id, Map.get(content, :version))
        :held -> install_and_hold(id, Map.get(content, :version))
        :removed -> remove(id)
      end
    end
  end

  @impl true
  def delete(_host, id) do
    if sandbox?() do
      delete_sandbox(id)
    else
      remove(id)
    end
  end

  @impl true
  def to_declaration(name, %{state: state} = content) do
    fields =
      [
        {:state, inspect(state)},
        content[:version] && {:version, inspect(content.version)}
      ]
      |> Enum.filter(& &1)

    Mjolnir.Forge.Resource.render_block("apt_package", name, fields)
  end

  @impl true
  def enumerate(_host) do
    if sandbox?() do
      list_sandbox_ids()
    else
      # Manually-installed packages only — enumerating every dependency would
      # bury the signal under hundreds of auto-installed packages.
      case System.cmd("apt-mark", ["showmanual"], stderr_to_stdout: true) do
        {out, 0} -> String.split(out, "\n", trim: true)
        {_, _} -> []
      end
    end
  end

  # -- Real apt commands --

  defp install(pkg, nil) do
    case System.cmd("apt-get", ["install", "-y", pkg], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:apt_install_failed, code, out}}
    end
  end

  defp install(pkg, version) do
    case System.cmd("apt-get", ["install", "-y", "#{pkg}=#{version}"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:apt_install_failed, code, out}}
    end
  end

  defp install_and_hold(pkg, version) do
    with :ok <- install(pkg, version) do
      case System.cmd("apt-mark", ["hold", pkg], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {out, code} -> {:error, {:apt_hold_failed, code, out}}
      end
    end
  end

  defp remove(pkg) do
    case System.cmd("apt-get", ["remove", "-y", pkg], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:apt_remove_failed, code, out}}
    end
  end

  # -- Sandbox (ETS-backed) --

  defp sandbox?, do: Application.get_env(:mjolnir, :forge_apt_sandbox, false)

  @sandbox_table :forge_apt_sandbox

  def ensure_sandbox_table do
    if :ets.whereis(@sandbox_table) == :undefined do
      :ets.new(@sandbox_table, [:named_table, :public, :set])
    end

    :ok
  end

  defp list_sandbox_ids do
    ensure_sandbox_table()
    :ets.tab2list(@sandbox_table) |> Enum.map(fn {id, _content} -> id end)
  end

  defp probe_sandbox(id) do
    ensure_sandbox_table()

    case :ets.lookup(@sandbox_table, id) do
      [{^id, content}] -> {:ok, content}
      [] -> :missing
    end
  end

  defp apply_sandbox(id, content) do
    ensure_sandbox_table()

    case content.state do
      :removed ->
        :ets.delete(@sandbox_table, id)
        :ok

      state when state in [:installed, :held] ->
        :ets.insert(@sandbox_table, {id, content})
        :ok
    end
  end

  defp delete_sandbox(id) do
    ensure_sandbox_table()
    :ets.delete(@sandbox_table, id)
    :ok
  end
end
