defmodule Mjolnir.API.HTTPTransportTest do
  use ExUnit.Case, async: false

  setup do
    original = Application.get_env(:mjolnir, :auth, [])
    Application.put_env(:mjolnir, :auth, Keyword.put(original, :bypass_localhost, false))
    on_exit(fn -> Application.put_env(:mjolnir, :auth, original) end)

    server = start_supervised!({Bandit, plug: Mjolnir.API.Router, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    %{port: port}
  end

  for protocol <- [:http1, :http2] do
    test "#{protocol} serves health and enforces API authentication", %{port: port} do
      protocol = unquote(protocol)
      {:ok, connection} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [protocol])
      assert Mint.HTTP.protocol(connection) == protocol
      {:ok, connection, ref} = Mint.HTTP.request(connection, "GET", "/api/health", [], nil)
      {connection, response} = collect(connection, ref, %{body: ""})
      assert response.status == 200
      assert Jason.decode!(response.body)["status"] == "ok"

      {:ok, connection, ref} = Mint.HTTP.request(connection, "GET", "/api/vms", [], nil)
      {connection, response} = collect(connection, ref, %{body: ""})
      assert response.status == 401
      Mint.HTTP.close(connection)
    end
  end

  defp collect(connection, ref, response) do
    receive do
      message ->
        case Mint.HTTP.stream(connection, message) do
          {:ok, connection, events} ->
            response =
              Enum.reduce(events, response, fn
                {:status, ^ref, status}, acc -> Map.put(acc, :status, status)
                {:data, ^ref, data}, acc -> %{acc | body: acc.body <> data}
                {:done, ^ref}, acc -> Map.put(acc, :done, true)
                _, acc -> acc
              end)

            if response[:done],
              do: {connection, response},
              else: collect(connection, ref, response)

          {:error, _connection, reason, _events} ->
            flunk("HTTP transport failed: #{inspect(reason)}")

          :unknown ->
            collect(connection, ref, response)
        end
    after
      5_000 -> flunk("HTTP response timed out")
    end
  end
end
