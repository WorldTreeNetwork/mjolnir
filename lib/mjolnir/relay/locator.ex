defmodule Mjolnir.Relay.Locator do
  @moduledoc false

  require Logger

  @env_path "/etc/mjolnir-relay/relay.env"
  @locator_path "/run/mjolnir-relay/locator.json"
  @max_bytes 4096
  @timeout_ms 500
  @env_keys ~w(MJOLNIR_RELAY_ENABLED MJOLNIR_RELAY_HOST)
  @dns_label ~S|[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?|
  @hostname Regex.compile!("\\A#{@dns_label}(?:\\.#{@dns_label})*\\z")
  @endpoint_id ~r/\A[0-9a-f]{64}\z/

  @doc "Resolve the host's public relay locators at guest identity setup."
  @spec read(keyword()) :: %{optional(String.t()) => String.t()}
  def read(opts \\ []) do
    case read_in_task(opts) do
      {:ok, locators} ->
        locators

      {:error, reason} ->
        Logger.warning("relay locator rejected: #{reason}")
        %{}
    end
  end

  defp read_in_task(opts) do
    task = Task.Supervisor.async_nolink(Mjolnir.TaskSupervisor, fn -> resolve(opts) end)

    case Task.yield(task, @timeout_ms) do
      {:ok, result} ->
        result

      {:exit, _} ->
        {:error, "file worker exited"}

      nil ->
        # Stop waiting even if the worker is still inside an OS file call.
        Task.ignore(task)
        Process.exit(task.pid, :kill)
        {:error, "timed out"}
    end
  catch
    :exit, _ -> {:error, "file worker unavailable"}
  end

  defp resolve(opts) do
    env_path =
      Keyword.get_lazy(opts, :env_path, fn ->
        Application.get_env(:mjolnir, :relay_locator_env_path, @env_path)
      end)

    with {:ok, env} <- File.read(env_path),
         true <- String.valid?(env),
         %{"MJOLNIR_RELAY_ENABLED" => "true", "MJOLNIR_RELAY_HOST" => host} <- assignments(env) do
      resolve_enabled(host, opts)
    else
      _ -> {:ok, %{}}
    end
  rescue
    _ -> {:error, "file worker failed"}
  end

  defp resolve_enabled(configured, opts) do
    locator_path =
      Keyword.get_lazy(opts, :locator_path, fn ->
        Application.get_env(:mjolnir, :relay_locator_path, @locator_path)
      end)

    lstat = Keyword.get(opts, :lstat, &File.lstat/1)

    with :ok <- validate_hostname(configured),
         host = String.downcase(configured, :ascii),
         {:ok, raw} <- read_bytes(locator_path, lstat),
         {:ok, live_host, endpoint_id} <- decode(raw),
         :ok <- validate_locators(host, live_host, endpoint_id) do
      {:ok, %{"relay_url" => "https://#{host}/", "relay_iroh_endpoint_id" => endpoint_id}}
    end
  end

  defp read_bytes(path, lstat) do
    case lstat.(path) do
      {:ok, %File.Stat{type: :regular, size: size} = stat} when size <= @max_bytes ->
        case File.open(path, [:read, :raw, :binary], &read_open_file(&1, stat)) do
          {:ok, result} -> result
          {:error, reason} -> {:error, "open failed (#{reason})"}
        end

      {:ok, %File.Stat{type: :regular}} ->
        {:error, "file exceeds #{@max_bytes} bytes"}

      {:ok, %File.Stat{type: type}} ->
        {:error, "non-regular file (#{type})"}

      {:error, reason} ->
        {:error, "lstat failed (#{reason})"}
    end
  end

  defp read_open_file(file, stat) do
    with {:ok, record} <- :file.read_file_info(file),
         %File.Stat{
           type: :regular,
           inode: inode,
           major_device: major,
           minor_device: minor
         } <- File.Stat.from_record(record),
         true <- {inode, major, minor} == {stat.inode, stat.major_device, stat.minor_device} do
      case :file.read(file, @max_bytes + 1) do
        {:ok, bytes} when byte_size(bytes) <= @max_bytes -> {:ok, bytes}
        {:ok, _} -> {:error, "file exceeds #{@max_bytes} bytes"}
        :eof -> {:ok, ""}
        {:error, reason} -> {:error, "read failed (#{reason})"}
      end
    else
      _ -> {:error, "file changed after lstat"}
    end
  end

  defp decode(raw) do
    with {:ok, %Jason.OrderedObject{values: [_, _] = fields}} <-
           Jason.decode(raw, objects: :ordered_objects),
         %{"host" => host, "endpoint_id" => id} when is_binary(host) and is_binary(id) <-
           Map.new(fields) do
      {:ok, host, id}
    else
      _ -> {:error, "invalid JSON or schema"}
    end
  end

  defp validate_hostname(host) do
    if is_binary(host) and byte_size(host) <= 253 and Regex.match?(@hostname, host),
      do: :ok,
      else: {:error, "invalid configured hostname"}
  end

  defp validate_locators(host, live_host, endpoint_id) do
    cond do
      String.downcase(live_host, :ascii) != host -> {:error, "hostname mismatch"}
      not Regex.match?(@endpoint_id, endpoint_id) -> {:error, "invalid endpoint ID"}
      true -> :ok
    end
  end

  defp assignments(env) do
    for line <- String.split(env, "\n"),
        [key, value] <- [String.split(line, "=", parts: 2)],
        key = String.trim(key),
        key in @env_keys,
        into: %{} do
      {key, assignment_value(String.trim(value))}
    end
  end

  defp assignment_value(<<quote, rest::binary>>) when quote in [?", ?'] do
    case String.split(rest, <<quote>>, parts: 2) do
      [value, ""] -> value
      _ -> nil
    end
  end

  defp assignment_value(value), do: value
end
