defmodule Mjolnir.MCP.Plug do
  @moduledoc "Authenticated legacy MCP HTTP transport."
  @behaviour Plug
  import Plug.Conn
  alias Mjolnir.MCP.Authorization

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    context = Authorization.context(conn)

    with {:ok, conn} <- prepare_request(conn),
         true <- Authorization.request_allowed?(context, conn.body_params) do
      transport = fn connection ->
        ExMCP.HttpPlug.call(
          connection,
          ExMCP.HttpPlug.init(
            handler: Mjolnir.MCP.Server,
            handler_opts: context,
            handler_call_timeout: 310_000,
            principal_id: Authorization.session_principal(context),
            protocol_mode: :legacy_only,
            legacy_http_sse: true,
            server_info: %{name: "mjolnir", version: to_string(Application.spec(:mjolnir, :vsn))},
            cors_enabled: false
          )
        )
      end

      if conn.method == "GET",
        do: Mjolnir.MCP.StreamOwner.run(conn, transport),
        else: transport.(conn)
    else
      false -> reject(conn, 403, "insufficient_scope")
      {:error, status} -> reject(conn, status, "invalid_request")
    end
  end

  # Router leaves MCP bodies untouched for the transport. Decode one bounded
  # body here so authorization and ExMCP process exactly the same request.
  # Current scopes must be checked even for an existing session initialized
  # with a more privileged token for this same principal.
  defp prepare_request(%{method: "POST"} = conn) do
    case read_body(conn, length: 1_000_000, read_length: 1_000_000) do
      {:ok, "", conn} when is_map(conn.body_params) ->
        if is_struct(conn.body_params),
          do: {:error, 400},
          else: decoded(conn, Jason.encode!(conn.body_params))

      {:ok, raw, conn} ->
        decoded(conn, raw)

      {:more, _, _} ->
        {:error, 413}

      {:error, _} ->
        {:error, 400}
    end
  end

  defp prepare_request(conn), do: {:ok, conn}

  defp decoded(conn, raw) when byte_size(raw) <= 1_000_000 do
    case Jason.decode(raw) do
      {:ok, request} when is_map(request) ->
        {:ok, conn |> Map.put(:body_params, request) |> assign(:raw_body, raw)}

      _ ->
        {:error, 400}
    end
  end

  defp decoded(_, _), do: {:error, 413}

  defp reject(conn, status, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: reason}))
    |> halt()
  end
end
