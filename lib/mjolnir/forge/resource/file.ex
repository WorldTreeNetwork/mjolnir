defmodule Mjolnir.Forge.Resource.File do
  @moduledoc """
  Resource kind: a plain file at an arbitrary path.

  Content shape:
  `%{path: binary(), source: binary(), mode: 0..0o777 | nil, owner: binary() | nil, group: binary() | nil}`.

  ## v0 drift semantics

  Like `SystemdUnit`, only `source` bytes are diffed for drift detection.
  `mode`, `owner`, and `group` are **apply-time intentions**: every call to
  `apply/3` re-asserts the declared mode/owner/group, but they are NOT
  observed for drift detection in v0. (A follow-up ticket may add full
  mode/ownership observation via `File.stat!` + `getent passwd`.)

  This means a hand-edit that flips `chmod 644 -> 755` on a Forge-managed
  file will NOT be flagged as drift in v0 — only content edits will. Apply
  always re-asserts the declared mode, so the next apply makes it right.

  ## Sandbox support

  Tests should write to a fresh `System.tmp_dir!/0` subdirectory. No chroot
  config key is provided for v0; use tmp paths directly in tests.
  """

  @behaviour Mjolnir.Forge.Resource

  @impl true
  @spec kind() :: String.t()
  def kind, do: "file"

  @impl true
  @spec canonical(map()) :: binary()
  def canonical(%{source: source}) when is_binary(source), do: source

  @impl true
  @spec observe_path(String.t()) :: {:file, Path.t()}
  def observe_path(id), do: {:file, id}

  @impl true
  @spec parse_observed(binary()) :: map()
  def parse_observed(bytes) when is_binary(bytes) do
    %{source: bytes}
  end

  @impl true
  @spec probe(String.t(), String.t()) :: {:error, :file_backed_kind}
  def probe(_host, _id), do: {:error, :file_backed_kind}

  @impl true
  @spec apply(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def apply(_host, id, %{source: src} = content) when is_binary(src) do
    path = Map.get(content, :path) || id
    mode = Map.get(content, :mode, 0o644)
    owner = Map.get(content, :owner)
    group = Map.get(content, :group)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, src),
         :ok <- set_mode(path, mode),
         :ok <- maybe_chown(path, owner),
         :ok <- maybe_chgrp(path, group) do
      :ok
    end
  end

  @impl true
  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(_host, id) do
    case File.rm(id) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = err -> err
    end
  end

  # Always re-assert the declared mode. No shortcut for 0o644 — leaving it
  # out would mean a file that drifted to 0o755 wouldn't get reset on apply.
  defp set_mode(_path, nil), do: :ok

  defp set_mode(path, mode) when is_integer(mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  defp maybe_chown(_path, nil), do: :ok

  defp maybe_chown(path, owner) when is_binary(owner) do
    case System.cmd("chown", [owner, path], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:chown_failed, code, out}}
    end
  end

  defp maybe_chgrp(_path, nil), do: :ok

  defp maybe_chgrp(path, group) when is_binary(group) do
    case System.cmd("chgrp", [group, path], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:chgrp_failed, code, out}}
    end
  end
end
