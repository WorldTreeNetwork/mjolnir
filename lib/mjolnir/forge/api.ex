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

  ## v1 endpoints

      GET  /events?since=&limit=  — recent audit events as JSON
      GET  /events/stream?since=  — Server-Sent Events (text/event-stream)

  Deferred: /diff/:host/:kind/:id, /adopt, /ignore.
  """

  use Plug.Router
  require Logger

  alias Mjolnir.Forge.{AuditLog, Declarations, EventBus, Events, Host, Store, Supervisor}

  # How often to send an SSE comment heartbeat, so proxies/load balancers
  # don't reap an idle stream.
  @sse_heartbeat_ms 15_000

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

  ## Discovery

  # Enumerate undeclared resources across enumerable kinds, classify them, and
  # upsert into the store. Returns the discovered (`:unmanaged`) entries so the
  # TUI can surface adoptable resources alongside the reconciler view.
  get "/discover" do
    case fetch_host(conn) do
      {:ok, host} ->
        entries = Host.discover(host) |> Enum.map(&entry_to_map/1)
        json(conn, 200, %{host: host, entries: entries})

      {:error, code, msg} ->
        json(conn, code, %{error: msg})
    end
  end

  ## Diff / adopt / ignore

  # Materialized declared-vs-observed content for one resource (the diff view).
  get "/diff" do
    with {:ok, host} <- fetch_host(conn),
         {:ok, kind_mod} <- fetch_kind(conn, conn.query_params["kind"]),
         {:ok, id} <- fetch_id(conn.query_params["id"]) do
      case Host.diff_one(host, {kind_mod, id}) do
        nil ->
          json(conn, 404, %{error: "not_found"})

        entry ->
          json(conn, 200, %{
            host: host,
            kind: kind_mod.kind(),
            id: id,
            status: Atom.to_string(entry.status),
            declared: render_content(kind_mod, entry.declared_content),
            observed: render_content(kind_mod, entry.observed_content)
          })
      end
    else
      {:error, code, msg} -> json(conn, code, %{error: msg})
    end
  end

  # Adopt an unmanaged resource: author a declaration from observed state +
  # take ownership. Body: {host, kind, id}.
  post "/adopt" do
    with {:ok, host, kind_mod, id} <- fetch_body_key(conn) do
      case Host.adopt(host, {kind_mod, id}) do
        :ok ->
          json(conn, 200, %{host: host, kind: kind_mod.kind(), id: id, result: "ok"})

        {:error, reason} ->
          json(conn, 422, %{error: "adopt_failed", reason: inspect(reason)})
      end
    else
      {:error, code, msg} -> json(conn, code, %{error: msg})
    end
  end

  # Mark an unmanaged resource ignored. Body: {host, kind, id}.
  post "/ignore" do
    with {:ok, host, kind_mod, id} <- fetch_body_key(conn) do
      case Host.ignore(host, {kind_mod, id}) do
        :ok ->
          json(conn, 200, %{host: host, kind: kind_mod.kind(), id: id, result: "ignored"})

        {:error, reason} ->
          json(conn, 422, %{error: "ignore_failed", reason: inspect(reason)})
      end
    else
      {:error, code, msg} -> json(conn, code, %{error: msg})
    end
  end

  # Declaration source file for a resource (the TUI's `e:edit`). `path` is null
  # when the resource isn't declared.
  get "/decl-path" do
    with {:ok, host} <- fetch_host(conn),
         {:ok, kind_mod} <- fetch_kind(conn, conn.query_params["kind"]),
         {:ok, id} <- fetch_id(conn.query_params["id"]) do
      path = Declarations.source_path(host, kind_mod.kind(), id)
      json(conn, 200, %{host: host, kind: kind_mod.kind(), id: id, path: path})
    else
      {:error, code, msg} -> json(conn, code, %{error: msg})
    end
  end

  ## Events

  # Recent audit events as a JSON array. `?since=<id>` returns everything after
  # that cursor; otherwise the last `?limit=` (default 100) events.
  get "/events" do
    events =
      case parse_cursor(conn.query_params["since"]) do
        nil -> AuditLog.recent(parse_limit(conn.query_params["limit"]))
        cursor -> AuditLog.since(cursor)
      end

    json(conn, 200, %{events: Enum.map(events, &Events.to_json/1)})
  end

  # Live Server-Sent Events. `?since=<id>` replays the backlog after that
  # cursor before switching to live frames. The request handler blocks here
  # for the life of the connection (Bandit gives each request its own process).
  get "/events/stream" do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    :ok = EventBus.subscribe(:all)

    backlog =
      case parse_cursor(conn.query_params["since"]) do
        nil -> []
        cursor -> AuditLog.since(cursor)
      end

    case replay(conn, backlog) do
      {:ok, conn} ->
        schedule_heartbeat()
        sse_loop(conn)

      {:error, _reason, conn} ->
        conn
    end
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  ## SSE internals

  defp replay(conn, events) do
    Enum.reduce_while(events, {:ok, conn}, fn event, {:ok, conn} ->
      case chunk(conn, Events.to_sse(event)) do
        {:ok, conn} -> {:cont, {:ok, conn}}
        {:error, reason} -> {:halt, {:error, reason, conn}}
      end
    end)
  end

  defp sse_loop(conn) do
    receive do
      {:forge_event, event} ->
        case chunk(conn, Events.to_sse(event)) do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end

      :heartbeat ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} ->
            schedule_heartbeat()
            sse_loop(conn)

          {:error, _} ->
            conn
        end

      # Cooperative shutdown — used by tests and graceful teardown so the
      # blocking handler returns the accumulated conn instead of hanging.
      :close ->
        conn
    end
  end

  defp schedule_heartbeat, do: Process.send_after(self(), :heartbeat, @sse_heartbeat_ms)

  defp parse_cursor(nil), do: nil
  defp parse_cursor(""), do: nil

  defp parse_cursor(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_limit(nil), do: 100

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n > 0 -> min(n, 1000)
      _ -> 100
    end
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

  defp fetch_kind(_conn, kind) when is_binary(kind) and kind != "" do
    case Store.kind_to_module(kind) do
      nil -> {:error, 400, "unknown kind: #{kind}"}
      mod -> {:ok, mod}
    end
  end

  defp fetch_kind(_conn, _), do: {:error, 400, "kind is required"}

  defp fetch_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp fetch_id(_), do: {:error, 400, "id is required"}

  # Parse a {host, kind, id} body into a resolved {host, kind_module, id}.
  defp fetch_body_key(conn) do
    body = conn.body_params || %{}

    with %{"host" => host, "kind" => kind, "id" => id}
         when is_binary(host) and host != "" and is_binary(id) and id != "" <- body,
         {:ok, kind_mod} <- fetch_kind(conn, kind) do
      {:ok, host, kind_mod, id}
    else
      {:error, _, _} = err -> err
      _ -> {:error, 400, "host, kind, and id are required"}
    end
  end

  # Render a resource's content to its canonical text form for the diff view.
  # nil content (declared/observed absent) → nil; a serialization error is
  # surfaced rather than crashing the request.
  defp render_content(_kind_mod, nil), do: nil

  defp render_content(kind_mod, content) do
    kind_mod.canonical(content)
  rescue
    _ -> nil
  end

  defp parse_apply_keys(%{"keys" => "all_safe"}), do: {:ok, :all_safe}

  defp parse_apply_keys(%{"keys" => keys}) when is_list(keys) do
    parsed =
      Enum.map(keys, fn
        %{"kind" => k, "id" => id} -> {Store.kind_to_module(k), id}
        _ -> :bad
      end)

    if Enum.any?(parsed, &(&1 == :bad or elem(&1, 0) == nil)) do
      {:error,
       "keys must be a list of {kind, id} maps with known kinds, or the string \"all_safe\""}
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
