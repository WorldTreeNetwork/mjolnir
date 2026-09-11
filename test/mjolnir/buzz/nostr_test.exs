defmodule Mjolnir.Buzz.NostrTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Buzz.Nostr

  defp mention(content \\ "wake up") do
    %{
      "id" => String.duplicate("a", 64),
      "pubkey" => String.duplicate("b", 64),
      "created_at" => 1_700_000_000,
      "kind" => 9,
      "tags" => [["p", "deadbeef"]],
      "content" => content,
      "sig" => String.duplicate("c", 128)
    }
  end

  test "producer is the Nostr ingress, not guest or Reconcile" do
    assert Nostr.producer() == "nostr"
  end

  test "conform returns a NIP-01-shaped event" do
    assert {:ok, event} = Nostr.conform(mention())
    assert event["kind"] == 9
    assert event["content"] == "wake up"
    assert event["tags"] == [["p", "deadbeef"]]
    assert event["id"] == String.duplicate("a", 64)
    assert event["pubkey"] == String.duplicate("b", 64)
    assert event["created_at"] == 1_700_000_000
    assert event["sig"] == String.duplicate("c", 128)
  end

  test "emulated event without id/sig still last-hops as NIP-01" do
    assert {:ok, event} = Nostr.conform(%{"kind" => 9, "content" => "hi"})
    assert event["kind"] == 9
    assert event["content"] == "hi"
    assert event["tags"] == []
    assert is_binary(event["id"])
    assert is_integer(event["created_at"]) and event["created_at"] >= 0
  end

  test "missing kind or content is invalid" do
    assert {:error, :invalid_event} = Nostr.conform(%{"content" => "x"})
    assert {:error, :invalid_event} = Nostr.conform(%{"kind" => 9})
    assert {:error, :invalid_event} = Nostr.conform("not a map")
    assert {:error, :invalid_event} = Nostr.conform(%{"kind" => "9", "content" => "x"})
  end

  test "to_internal is a wake envelope, not a Buzz kind log record" do
    {:ok, nostr} = Nostr.conform(mention())
    internal = Nostr.to_internal(nostr, "vm-1", 0)
    assert internal["type"] == "buzz.wake"
    assert internal["producer"] == "nostr"
    assert internal["attestation"] == %{"vm_id" => "vm-1", "epoch" => 0}
    assert internal["nostr"]["kind"] == 9
    refute internal["type"] == 9
  end

  test "last hop extracts the conformant Nostr event" do
    {:ok, nostr} = Nostr.conform(mention("ping"))
    internal = Nostr.to_internal(nostr, "vm-1", 2)
    assert {:ok, hop} = Nostr.last_hop(internal)
    assert hop["content"] == "ping"
    assert hop["kind"] == 9
  end
end
