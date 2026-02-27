defmodule Mjolnir.MCP.Plug do
  @moduledoc """
  Plug adapter routing /mcp requests to the ExMCP HTTP transport.
  Handles Streamable HTTP: POST for JSON-RPC, GET for SSE streams.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    ExMCP.HttpPlug.call(
      conn,
      ExMCP.HttpPlug.init(
        handler: Mjolnir.MCP.Server,
        server_info: %{name: "mjolnir", version: to_string(Application.spec(:mjolnir, :vsn))},
        sse_enabled: true,
        cors_enabled: false
      )
    )
  end
end
