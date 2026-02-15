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

  @doc """
  Build a configure_network request message.
  Guest agent will configure eth0 with the given IP.
  """
  def configure_network_request(ip, request_id \\ nil) do
    %{
      "type" => "configure_network",
      "id" => request_id || UUID.uuid4(),
      "ip" => ip
    }
  end

  @doc """
  Build a configure_ssh request message.
  Guest agent will write the given authorized_keys to /root/.ssh/authorized_keys.
  """
  def configure_ssh_request(authorized_keys, request_id \\ nil) do
    %{
      "type" => "configure_ssh",
      "id" => request_id || UUID.uuid4(),
      "authorized_keys" => authorized_keys
    }
  end

  @doc """
  Build a configure_identity request message.
  Guest agent will write /etc/mjolnir/vm.json with vm_id and api_url.
  """
  def configure_identity_request(vm_id, api_url, request_id \\ nil) do
    %{
      "type" => "configure_identity",
      "id" => request_id || UUID.uuid4(),
      "vm_id" => vm_id,
      "api_url" => api_url
    }
  end

  @doc """
  Build a get_iroh_status request message.
  Guest agent will return the current Iroh status.
  """
  def get_iroh_status_request(request_id \\ nil) do
    %{
      "type" => "get_iroh_status",
      "id" => request_id || UUID.uuid4()
    }
  end

  @doc """
  Build a configure_iroh request message.
  Tells the guest agent whether to start Iroh networking.
  """
  def configure_iroh_request(enabled, request_id \\ nil) do
    %{
      "type" => "configure_iroh",
      "id" => request_id || UUID.uuid4(),
      "enabled" => enabled
    }
  end

  @doc """
  Parse an iroh_ready message from the guest.

  The guest agent sends this proactively when its Iroh endpoint connects to relay.

  Returns `{:ok, %{node_id: string, ticket: string, generated_key: bool}}` or `{:error, reason}`.
  """
  def parse_iroh_ready(%{"type" => "iroh_ready", "node_id" => node_id, "ticket" => ticket} = msg) do
    {:ok,
     %{
       node_id: node_id,
       ticket: ticket,
       generated_key: Map.get(msg, "generated_key", true)
     }}
  end

  def parse_iroh_ready(_), do: {:error, :invalid_iroh_ready}
end
