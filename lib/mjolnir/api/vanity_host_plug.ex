defmodule Mjolnir.API.VanityHostPlug do
  @moduledoc """
  Plug that intercepts requests from custom-domain (vanity) hosts and serves
  the appropriate IdentiKey site.

  For each incoming request:
  1. Reads the `Host` header (strip port if present).
  2. Skips if the host is `localhost`, `127.0.0.1`, or the configured
     `api_host_bind` application env value.
  3. Skips if the path starts with `/api/`.
  4. Looks up the host in `SecretStore.lookup_alias/1`.
  5. On hit: calls `Sites.Server.serve/3`, writes the response, halts the conn.
  6. On miss: passes through to the normal router match/dispatch.
  """

  import Plug.Conn

  alias Mjolnir.SecretStore
  alias Mjolnir.Sites.Server

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    host = get_host(conn)

    cond do
      is_nil(host) ->
        conn

      skip_host?(host) ->
        conn

      String.starts_with?(conn.request_path, "/api/") ->
        conn

      true ->
        handle_vanity(conn, host)
    end
  end

  ## Internals

  defp get_host(conn) do
    # Prefer the Host header (set by real HTTP clients and Plug.Test via
    # Map.put(:host, ...)), falling back to conn.host which Bandit populates.
    case get_req_header(conn, "host") do
      [h | _] -> strip_port(h)
      [] -> if is_binary(conn.host) and conn.host != "", do: strip_port(conn.host), else: nil
    end
  end

  defp strip_port(host) when is_binary(host) do
    case String.split(host, ":", parts: 2) do
      [h, _port] -> h
      [h] -> h
    end
  end

  defp strip_port(nil), do: nil

  @loopback_hosts ["localhost", "127.0.0.1", "::1", "0.0.0.0"]

  defp skip_host?(host) do
    api_bind = Application.get_env(:mjolnir, :api_host_bind)

    host in @loopback_hosts or
      (is_binary(api_bind) and host == api_bind)
  end

  defp handle_vanity(conn, host) do
    case SecretStore.lookup_alias(host) do
      {:ok, {fp, site_name}} ->
        serve_vanity(conn, fp, site_name)

      :not_found ->
        conn
    end
  end

  defp serve_vanity(conn, fp, site_name) do
    request_path =
      case conn.request_path do
        "" -> "/"
        p -> p
      end

    case Server.serve(fp, site_name, request_path) do
      {:ok, %{status: status, content_type: ct, content_encoding: ce, body: body}} ->
        conn = put_resp_content_type(conn, ct, nil)
        conn = if ce, do: put_resp_header(conn, "content-encoding", ce), else: conn

        conn
        |> send_resp(status, body)
        |> halt()

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, ~s({"error":"not_found"}))
        |> halt()

      {:error, :no_head} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, ~s({"error":"no_head"}))
        |> halt()

      {:error, :no_manifest} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, ~s({"error":"manifest_unavailable"}))
        |> halt()

      {:error, :chunk_missing} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, ~s({"error":"chunk_missing"}))
        |> halt()

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, ~s({"error":"serve_failed"}))
        |> halt()
    end
  end
end
