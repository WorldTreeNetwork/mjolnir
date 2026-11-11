defmodule Mjolnir.API.AieRouter do
  @moduledoc "AIE ceremonies authenticate their own holder proofs, without operator scopes."
  import Plug.Conn
  alias Mjolnir.Aie.Execute
  @behaviour Plug
  def init(opts), do: opts

  def call(%{path_info: ["api", "aie" | path]} = conn, _opts) do
    result =
      case {conn.method, path} do
        {"GET", ["challenge"]} -> {:ok, Execute.challenge()}
        {"GET", ["offers", owner, id]} -> Execute.share(owner, id)
        {"POST", ["mint"]} -> Execute.mint(conn.body_params)
        {"POST", ["prepare"]} -> Execute.prepare(conn.body_params)
        {"POST", ["check"]} -> Execute.check(conn.body_params)
        _ -> {:error, :not_found}
      end

    case result do
      {:ok, body} -> json(conn, 200, body)
      {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      _ -> json(conn, 403, %{error: "forbidden"})
    end
  rescue
    _ -> json(conn, 403, %{error: "forbidden"})
  end

  def call(conn, _opts), do: conn

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
