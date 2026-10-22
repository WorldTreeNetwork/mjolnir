defmodule Mjolnir.Buzz.Nostr do
  @moduledoc """
  NIP-01-shaped events for the Buzz facade.

  Ingress translates a mention into an internal mailbox message. The last hop
  back into a Buzz body is a conformant Nostr event for `buzz-acp`. The host
  does not persist these kinds as an event log; the relay remains the log.
  """

  @producer "nostr"

  @type event :: map()
  @type internal :: map()

  @doc "Named wake producer. Not the guest, Reconcile, or a desktop side channel."
  @spec producer() :: String.t()
  def producer, do: @producer

  @doc """
  Accept a mention or emulated Nostr event and return a NIP-01-shaped map.
  """
  @spec conform(term()) :: {:ok, event()} | {:error, :invalid_event}
  def conform(event) when is_map(event) do
    kind = Map.get(event, "kind") || Map.get(event, :kind)
    content = Map.get(event, "content") || Map.get(event, :content)
    tags = Map.get(event, "tags") || Map.get(event, :tags) || []

    cond do
      not is_integer(kind) -> {:error, :invalid_event}
      not is_binary(content) -> {:error, :invalid_event}
      not is_list(tags) -> {:error, :invalid_event}
      true -> {:ok, nip01(event, kind, content, tags)}
    end
  end

  def conform(_), do: {:error, :invalid_event}

  @doc """
  Internal OTP message. Attestation is the v1 Admit shape. Nested `nostr` is
  the last hop for `buzz-acp`. Type is `buzz.wake`, not a Nostr kind.
  """
  @spec to_internal(event(), String.t(), non_neg_integer()) :: internal()
  def to_internal(nostr, vm_id, epoch)
      when is_map(nostr) and is_binary(vm_id) and is_integer(epoch) and epoch >= 0 do
    %{
      "type" => "buzz.wake",
      "producer" => @producer,
      "attestation" => %{"vm_id" => vm_id, "epoch" => epoch},
      "nostr" => nostr
    }
  end

  @doc "Last hop: the conformant Nostr event presented to the guest harness."
  @spec last_hop(term()) :: {:ok, event()} | {:error, :invalid_event}
  def last_hop(%{"nostr" => event}) when is_map(event), do: conform(event)
  def last_hop(%{nostr: event}) when is_map(event), do: conform(event)
  def last_hop(event) when is_map(event), do: conform(event)
  def last_hop(_), do: {:error, :invalid_event}

  defp nip01(event, kind, content, tags) do
    %{
      "id" => string_field(event, "id", :id, ""),
      "pubkey" => string_field(event, "pubkey", :pubkey, ""),
      "created_at" => int_field(event, "created_at", :created_at, System.os_time(:second)),
      "kind" => kind,
      "tags" => tags,
      "content" => content,
      "sig" => string_field(event, "sig", :sig, "")
    }
  end

  defp string_field(event, sk, ak, default) do
    case Map.get(event, sk) || Map.get(event, ak) do
      value when is_binary(value) -> value
      _ -> default
    end
  end

  defp int_field(event, sk, ak, default) do
    case Map.get(event, sk) || Map.get(event, ak) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end
end
