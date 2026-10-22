defmodule Mjolnir.Buzz.FacadeTest do
  use ExUnit.Case, async: false

  alias Mjolnir.{Buzz.Facade, Buzz.Nostr, DormantRegistry, Mailbox, VM}

  setup do
    root = Path.join(System.tmp_dir!(), "mjolnir-buzz-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:mjolnir, :btrfs_root)
    Application.put_env(:mjolnir, :btrfs_root, root)
    vm_id = "buzz-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if Process.whereis(DormantRegistry), do: DormantRegistry.unregister(vm_id)
      _ = Mailbox.drop_mailbox(vm_id)
      Application.put_env(:mjolnir, :btrfs_root, previous)
      File.rm_rf(root)
    end)

    %{vm_id: vm_id, root: root}
  end

  defp mention(content \\ "hello from hive") do
    %{
      "id" => String.duplicate("a", 64),
      "pubkey" => String.duplicate("b", 64),
      "created_at" => 1_700_000_000,
      "kind" => 9,
      "tags" => [["p", "cafe"]],
      "content" => content,
      "sig" => String.duplicate("c", 128)
    }
  end

  test "facade is supervised under the application" do
    assert is_pid(Process.whereis(Facade))
  end

  test "host is not a second event log" do
    state = :sys.get_state(Facade)
    refute Map.has_key?(state, :events)
    refute Map.has_key?(state, :log)
    refute Map.has_key?(state, :kinds)
  end

  test "running body mention stays on the relay; mailbox unused", %{vm_id: vm_id} do
    {:ok, _} = Registry.register(Mjolnir.VMRegistry, vm_id, :buzz_test)

    assert {:ok, %{verdict: :drop, reason: :relay}} =
             Facade.ingest(mention(), vm_id: vm_id)

    assert [] = Mailbox.list_unacked(vm_id)
    assert [] = DormantRegistry.take_pending_messages(vm_id)
  end

  test "dormant body: ingress is the wake producer and last hop is Nostr", %{vm_id: vm_id} do
    :ok = DormantRegistry.register(vm_id, "snap-buzz", %{})
    event = mention("mention")

    assert {:ok, %{verdict: :deliver, nostr: hop, message_id: message_id}} =
             Facade.ingest(event, vm_id: vm_id, epoch: 0)

    assert is_binary(message_id)
    assert hop["kind"] == 9
    assert hop["content"] == "mention"
    assert {:ok, hop} == Nostr.last_hop(hop)

    [mail] = Mailbox.list_unacked(vm_id)
    assert mail["from_vm_id"] == Nostr.producer()
    assert mail["payload"]["producer"] == "nostr"
    assert mail["payload"]["type"] == "buzz.wake"
    assert mail["payload"]["attestation"] == %{"vm_id" => vm_id, "epoch" => 0}
    assert mail["payload"]["nostr"]["kind"] == 9
    refute mail["payload"]["type"] == 9
  end

  test "dormant junk does not thaw or queue", %{vm_id: vm_id} do
    :ok = DormantRegistry.register(vm_id, "snap-buzz", %{})

    assert {:error, :invalid_event} = Facade.ingest(%{"content" => "no kind"}, vm_id: vm_id)

    assert {:ok, %{verdict: :deny, reason: :admission_denied}} =
             Facade.ingest_internal(%{"wake" => true, "type" => "buzz.wake"}, vm_id: vm_id)

    assert [] = Mailbox.list_unacked(vm_id)
    assert [] = DormantRegistry.take_pending_messages(vm_id)
    assert {:ok, entry} = DormantRegistry.lookup(vm_id)
    assert entry.state == :dormant
  end

  test "unknown vm is deny and writes nothing", %{vm_id: vm_id} do
    assert {:ok, %{verdict: :deny, reason: :not_found}} =
             Facade.ingest(mention(), vm_id: vm_id)

    assert [] = Mailbox.list_unacked(vm_id)
  end

  test "ingest requires a vm_id" do
    assert {:error, :invalid_event} = Facade.ingest(mention())
  end

  test "later protocols share ingest_internal, not a second thaw path", %{vm_id: vm_id} do
    :ok = DormantRegistry.register(vm_id, "snap-buzz", %{})
    {:ok, nostr} = Nostr.conform(mention("matrix-emulated"))
    internal = Nostr.to_internal(nostr, vm_id, 0)

    assert {:ok, %{verdict: :deliver, nostr: hop}} =
             Facade.ingest_internal(internal, vm_id: vm_id)

    assert hop["content"] == "matrix-emulated"
    assert hd(Mailbox.list_unacked(vm_id))["from_vm_id"] == "nostr"
  end

  test "trusted hop is deliver_message; Admit still fail-closes", %{vm_id: vm_id} do
    :ok = DormantRegistry.register(vm_id, "snap-buzz", %{})
    payload = %{"wake" => true}

    assert {:error, :admission_denied} = VM.deliver_message(vm_id, "nostr", payload)
    assert [] = Mailbox.list_unacked(vm_id)
  end
end
