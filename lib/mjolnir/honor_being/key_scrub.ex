defmodule Mjolnir.HonorBeing.KeyScrub do
  @moduledoc """
  Strip `XAI_API_KEY` from a guest rootfs before a hosted-being snapshot.

  The key belongs in `/run/mjolnir/` tmpfs (not this tree). Bootstrap already
  refuses a storefront `.env` that contains it; grok config and shell history
  were unguarded until `mj snapshot create hosted-*`.
  """

  @key "XAI_API_KEY"
  @key_re ~r/XAI_API_KEY/

  @rel_files [
    ".env",
    ".env.local",
    ".bashrc",
    ".profile",
    ".bash_profile",
    ".zshrc",
    ".zprofile",
    ".bash_history",
    ".zsh_history",
    ".python_history"
  ]

  @rel_dirs [
    ".config/grok",
    ".grok",
    ".config/xai",
    ".local/share/grok"
  ]

  @workdir_env "root/hypersigil-store-frontend/.env"

  @doc """
  Hosted-being snapshots are named `hosted-<xid>` or `hosted-devpreview-test`.
  """
  def hosted_snapshot_name?("hosted-" <> _rest), do: true
  def hosted_snapshot_name?(_), do: false

  @doc """
  Best-effort strip. Missing rootfs is an error so a hosted snapshot cannot
  skip the guard. Missing individual files are fine.
  """
  @spec scrub_rootfs(String.t() | nil) :: :ok | {:error, :no_rootfs}
  def scrub_rootfs(rootfs) when is_binary(rootfs) do
    if File.dir?(rootfs) do
      Enum.each(targets(rootfs), &scrub_path/1)
      :ok
    else
      {:error, :no_rootfs}
    end
  end

  def scrub_rootfs(_), do: {:error, :no_rootfs}

  @doc false
  def contains_key?(rootfs) when is_binary(rootfs) do
    Enum.any?(targets(rootfs), &path_contains_key?/1)
  end

  defp targets(rootfs) do
    homes =
      [Path.join(rootfs, "root")] ++
        case File.ls(Path.join(rootfs, "home")) do
          {:ok, names} -> Enum.map(names, &Path.join([rootfs, "home", &1]))
          {:error, _} -> []
        end

    home_files =
      for home <- homes,
          rel <- @rel_files,
          do: Path.join(home, rel)

    home_dirs =
      for home <- homes,
          rel <- @rel_dirs,
          do: Path.join(home, rel)

    [Path.join(rootfs, @workdir_env) | home_files ++ home_dirs]
  end

  defp scrub_path(path) do
    cond do
      File.dir?(path) ->
        path
        |> list_files()
        |> Enum.each(&scrub_file/1)

      File.regular?(path) ->
        scrub_file(path)

      true ->
        :ok
    end
  end

  defp list_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.flat_map(fn p ->
          cond do
            File.dir?(p) -> list_files(p)
            File.regular?(p) -> [p]
            true -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp scrub_file(path) do
    case File.read(path) do
      {:ok, bin} ->
        if String.valid?(bin) and String.contains?(bin, @key) do
          cleaned =
            bin
            |> String.split("\n")
            |> Enum.reject(&Regex.match?(@key_re, &1))
            |> Enum.join("\n")

          _ = File.write(path, cleaned)
        end

      {:error, _} ->
        :ok
    end
  end

  defp path_contains_key?(path) do
    cond do
      File.dir?(path) ->
        Enum.any?(list_files(path), &file_contains_key?/1)

      File.regular?(path) ->
        file_contains_key?(path)

      true ->
        false
    end
  end

  defp file_contains_key?(path) do
    case File.read(path) do
      {:ok, bin} -> String.valid?(bin) and String.contains?(bin, @key)
      {:error, _} -> false
    end
  end
end
