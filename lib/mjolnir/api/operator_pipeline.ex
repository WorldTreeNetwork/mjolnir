defmodule Mjolnir.API.OperatorPipeline do
  @moduledoc """
  HTTP pipeline for the operator Unix socket.

  The socket's mode (`0600`, owner root) is the credential. This plug
  marks the connection before the router runs. The TCP listener does
  not use this pipeline, so a peer on `127.0.0.1` is not the operator.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> Plug.Conn.put_private(:mjolnir_operator, true)
    |> Mjolnir.API.Router.call(Mjolnir.API.Router.init([]))
  end
end
