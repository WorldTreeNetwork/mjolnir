defmodule Mjolnir.Relay.Locator do
  @moduledoc false

  @env_path "/etc/mjolnir-relay/relay.env"
  @locator_path "/run/mjolnir-relay/locator.json"
  @env_keys ~w(MJOLNIR_RELAY_ENABLED MJOLNIR_RELAY_HOST)
  @dns_label ~S|[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?|
  @hostname Regex.compile!("\\A#{@dns_label}(?:\\.#{@dns_label})*\\z")
  @endpoint_id ~r/\A[0-9a-f]{64}\z/

  @doc "Resolve the host's public relay locators at guest identity setup."
  @spec read(keyword()) :: %{optional(String.t()) => String.t()}
  def read(opts \\ []) do
    env_path = Keyword.get(opts, :env_path, @env_path)
    locator_path = Keyword.get(opts, :locator_path, @locator_path)

    with {:ok, env} <- File.read(env_path),
         true <- String.valid?(env),
         %{"MJOLNIR_RELAY_ENABLED" => "true", "MJOLNIR_RELAY_HOST" => configured} <-
           assignments(env),
         true <- hostname?(configured),
         host = String.downcase(configured, :ascii),
         {:ok, raw} <- File.read(locator_path),
         {:ok, %{"host" => live_host, "endpoint_id" => endpoint_id}} <- Jason.decode(raw),
         true <- is_binary(live_host) and String.downcase(live_host, :ascii) == host,
         true <- is_binary(endpoint_id) and Regex.match?(@endpoint_id, endpoint_id) do
      %{"relay_url" => "https://#{host}/", "relay_iroh_endpoint_id" => endpoint_id}
    else
      _ -> %{}
    end
  end

  defp hostname?(host) when is_binary(host),
    do: byte_size(host) <= 253 and Regex.match?(@hostname, host)

  defp hostname?(_), do: false

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
