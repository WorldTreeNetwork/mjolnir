defmodule Mjolnir.Forge.API do
  @moduledoc """
  HTTP API for the Forge subsystem. Forwarded from `Mjolnir.API.Router` at
  `/api/forge/*`. Auth: same localhost bypass as `/api/vms/*` — the SSH-
  tunneled curl pattern (`ssh host "curl localhost:4000/..."`) works
  without tokens.

  ## v0 endpoints

      GET  /hosts                 — list managed hosts
      POST /hosts                 — start a Host worker
      GET  /plan?host=H           — observe + diff, return entries
      POST /apply                 — body: {host, keys: [...] | "all_safe"}
      GET  /state                 — list Store records (filterable)

  Deferred to v1: /diff/:host/:kind/:id, /adopt, /ignore, /events, /events/stream.
  """

  use Plug.Router
  require Logger

  alias Mjolnir.Forge.{Declarations, Host, Store, Supervisor}

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["*/*"])
  plug(:dispatch)

  ## Hosts

  get "/hosts" do
    workers = list_workers()
    json(conn, 200, %{hosts: workers})
  end

  post "/hosts" do
    case conn.body_params do
      %{"host" => host} = body when is_binary(host) ->
        opts = [
          host: host,
          transport: parse_transport(Map.get(body, "transport", "local")),
          auto_apply: Map.get(body, "auto_apply", false)
        ]

        case Supervisor.start_host(opts) do
          {:ok, _pid} ->
            json(conn, 201, %{host: host, status: "started"})

          {:error, {:already_started, _pid}} ->
            json(conn, 200, %{host: host, status: "already_running"})

          {:error, reason} ->
            Logger.error("Forge.API start_host failed: #{inspect(reason)}")
            json(conn, 500, %{error: "start_failed", reason: inspect(reason)})
        end

      _ ->
        json(conn, 400, %{error: "host is required"})
    end
  end

  ## Plan / apply

  get "/plan" do
    case fetch_host(conn) do
      {:ok, host} ->
        entries = Host.plan(host) |> Enum.map(&entry_to_map/1)
        json(conn, 200, %{host: host, entries: entries})

      {:error, code, msg} ->
        json(conn, code, %{error: msg})
    end
  end

  post "/apply" do
    with %{"host" => host} <- conn.body_params || %{},
         {:ok, keys} <- parse_apply_keys(conn.body_params) do
      results = Host.apply(host, keys) |> Enum.map(&result_to_map/1)
      json(conn, 200, %{host: host, results: results})
    else
      {:error, msg} -> json(conn, 400, %{error: msg})
      _ -> json(conn, 400, %{error: "host is required"})
    end
  end

  ## State

  get "/state" do
    host = blank_to_nil(conn.query_params["host"])
    kind = blank_to_nil(conn.query_params["kind"])
    status = blank_to_nil(conn.query_params["status"])

    records =
      Store.list()
      |> Enum.filter(fn r ->
        (is_nil(host) or r.host == host) and
          (is_nil(kind) or r.kind == kind) and
          (is_nil(status) or Atom.to_string(r.status) == status)
      end)
      |> Enum.map(&record_to_map/1)

    json(conn, 200, %{records: records})
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  ## Helpers

  defp list_workers do
    declared_hosts = Declarations.hosts()
    running = Registry.select(Mjolnir.Forge.HostRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])

    (declared_hosts ++ running)
    |> Enum.uniq()
    |> Enum.map(fn host ->
      %{host: host, running: host in running, declared: host in declared_hosts}
    end)
  end

  defp parse_transport("ssh"), do: :ssh
  defp parse_transport(_), do: :local

  defp fetch_host(conn) do
    case conn.query_params["host"] do
      nil -> {:error, 400, "host query param required"}
      "" -> {:error, 400, "host query param required"}
      host -> {:ok, host}
    end
  end

  defp parse_apply_keys(%{"keys" => "all_safe"}), do: {:ok, :all_safe}
  defp parse_apply_keys(%{"keys" => keys}) when is_list(keys) do
    parsed =
      Enum.map(keys, fn
        %{"kind" => k, "id" => id} -> {Store.kind_to_module(k), id}
        _ -> :bad
      end)

    if Enum.any?(parsed, &(&1 == :bad or elem(&1, 0) == nil)) do
      {:error, "keys must be a list of {kind, id} maps with known kinds, or the string \"all_safe\""}
    else
      {:ok, parsed}
    end
  end

  defp parse_apply_keys(_), do: {:error, "keys is required"}

  defp entry_to_map(%{kind: kind, id: id, status: status} = entry) do
    %{
      kind: kind.kind(),
      id: id,
      status: Atom.to_string(status),
      declared_hash: hex(entry.declared_hash),
      owned_hash: hex(entry.owned_hash),
      observed_hash: hex(entry.observed_hash)
    }
  end

  defp result_to_map({{kind, id}, :ok}) do
    %{kind: kind.kind(), id: id, result: "ok"}
  end

  defp result_to_map({{kind, id}, {:error, reason}}) do
    %{kind: kind.kind(), id: id, result: "error", reason: inspect(reason)}
  end

  defp record_to_map(r) do
    %{
      host: r.host,
      kind: r.kind,
      resource_id: r.resource_id,
      status: Atom.to_string(r.status),
      declared_hash: hex(r.declared_hash),
      owned_hash: hex(r.owned_hash),
      observed_hash: hex(r.observed_hash),
      applied_at: encode_dt(r.applied_at),
      observed_at: encode_dt(r.observed_at),
      updated_at: encode_dt(r.updated_at)
    }
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s

  defp hex(nil), do: nil
  defp hex(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)

  defp encode_dt(nil), do: nil
  defp encode_dt(dt), do: DateTime.to_iso8601(dt)

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
