defmodule Mjolnir.Deploy.Secrets do
  @moduledoc """
  Host-escrowed deploy secrets: `/var/lib/mjolnir/deploy/secrets/<slug>.json`.

  Flat string map, injected at spawn. `put/2` merges. List returns names
  only — values never go in logs or API bodies.
  """

  require Logger

  @key_re ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @type listing :: %{app: String.t(), slug: String.t(), keys: [String.t()]}
  @type put_result :: %{app: String.t(), slug: String.t(), set: [String.t()], keys: [String.t()]}
  @type unset_result :: %{
          app: String.t(),
          slug: String.t(),
          unset: String.t(),
          keys: [String.t()]
        }

  @doc "Same slug as `Mjolnir.Deploy.Orchestrator` / Registry filenames."
  @spec slug(String.t()) :: String.t()
  def slug(app_name) when is_binary(app_name) do
    case app_name |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/, "_") do
      "" -> "app"
      s -> s
    end
  end

  @spec list_keys(String.t()) :: {:ok, listing()} | {:error, term()}
  def list_keys(app_name) when is_binary(app_name) do
    with {:ok, map} <- read_or_empty(app_name) do
      {:ok, %{app: app_name, slug: slug(app_name), keys: sorted_keys(map)}}
    end
  end

  @spec put(String.t(), map()) :: {:ok, put_result()} | {:error, term()}
  def put(app_name, entries) when is_binary(app_name) and is_map(entries) do
    with {:ok, entries} <- normalize_entries(entries),
         :ok <- validate_entries(entries),
         {:ok, existing} <- read_or_empty(app_name),
         merged = Map.merge(existing, entries),
         :ok <- write(app_name, merged) do
      set = sorted_keys(entries)
      Logger.info("Deploy secrets: set #{Enum.join(set, ", ")} on #{app_name}")
      {:ok, %{app: app_name, slug: slug(app_name), set: set, keys: sorted_keys(merged)}}
    end
  end

  @spec delete(String.t(), String.t()) :: {:ok, unset_result()} | {:error, term()}
  def delete(app_name, key) when is_binary(app_name) and is_binary(key) do
    with :ok <- validate_key(key),
         {:ok, existing} <- read_or_empty(app_name) do
      if Map.has_key?(existing, key) do
        merged = Map.delete(existing, key)

        with :ok <- write(app_name, merged) do
          Logger.info("Deploy secrets: unset #{key} on #{app_name}")
          {:ok, %{app: app_name, slug: slug(app_name), unset: key, keys: sorted_keys(merged)}}
        end
      else
        {:error, :not_found}
      end
    end
  end

  defp dir do
    Application.get_env(:mjolnir, :deploy_secrets_dir, "/var/lib/mjolnir/deploy/secrets")
  end

  defp path(app_name), do: Path.join(dir(), slug(app_name) <> ".json")

  defp read_or_empty(app_name) do
    case File.read(path(app_name)) do
      {:ok, bin} ->
        case Jason.decode(bin) do
          {:ok, map} when is_map(map) -> {:ok, stringify_map(map)}
          {:ok, _} -> {:error, :invalid_file}
          {:error, _} -> {:error, :invalid_file}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp stringify_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) and is_binary(v) -> {k, v}
      {k, v} when is_binary(v) -> {to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp normalize_entries(entries) do
    {:ok,
     Map.new(entries, fn
       {k, v} when is_binary(k) -> {k, v}
       {k, v} -> {to_string(k), v}
     end)}
  end

  defp validate_entries(entries) when map_size(entries) == 0, do: {:error, :empty}

  defp validate_entries(entries) do
    Enum.reduce_while(entries, :ok, fn {k, v}, _ ->
      case {validate_key(k), validate_value(k, v)} do
        {:ok, :ok} -> {:cont, :ok}
        {err, _} when err != :ok -> {:halt, err}
        {_, err} -> {:halt, err}
      end
    end)
  end

  defp validate_key(key) when is_binary(key) do
    if Regex.match?(@key_re, key), do: :ok, else: {:error, {:invalid_key, key}}
  end

  defp validate_key(key), do: {:error, {:invalid_key, key}}

  defp validate_value(_key, v) when is_binary(v) and v != "", do: :ok
  defp validate_value(key, _), do: {:error, {:invalid_value, key}}

  defp write(app_name, map) do
    dir = dir()
    final = path(app_name)
    tmp = final <> ".tmp"
    body = Jason.encode!(map)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, body),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, final),
         :ok <- File.chmod(final, 0o600) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:write_failed, reason}}
    end
  end

  defp sorted_keys(map), do: map |> Map.keys() |> Enum.sort()
end
