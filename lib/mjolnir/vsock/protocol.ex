defmodule Mjolnir.Vsock.Protocol do
  @moduledoc """
  Wire protocol for host↔guest communication over vsock.

  Message format:
  - 4 bytes: message length (big-endian uint32)
  - N bytes: JSON-encoded message body

  Message types:
  - exec_request: {type: "exec", id: "uuid", command: "string"}
  - exec_response: {type: "exec_response", id: "uuid", exit_code: int, stdout: "string", stderr: "string"}
  - ping: {type: "ping"}
  - pong: {type: "pong"}
  """

  @doc """
  Encode a message for transmission.
  """
  def encode(message) when is_map(message) do
    json = Jason.encode!(message)
    length = byte_size(json)
    <<length::big-32, json::binary>>
  end

  @doc """
  Decode a message from wire format.
  """
  def decode(<<length::big-32, json::binary-size(length)>>) do
    Jason.decode(json)
  end

  def decode(_), do: {:error, :invalid_message}

  @doc """
  Build an exec request message.
  """
  def exec_request(command, request_id \\ nil) do
    %{
      "type" => "exec",
      "id" => request_id || UUID.uuid4(),
      "command" => command
    }
  end

  @doc """
  Build a ping message.
  """
  def ping, do: %{"type" => "ping"}
end
