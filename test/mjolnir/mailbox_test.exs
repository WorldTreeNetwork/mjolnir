defmodule Mjolnir.MailboxTest do
  use ExUnit.Case, async: false

  alias Mjolnir.Mailbox

  setup do
    root = Path.join(System.tmp_dir!(), "mjolnir-mail-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:mjolnir, :btrfs_root)
    Application.put_env(:mjolnir, :btrfs_root, root)

    on_exit(fn ->
      Application.put_env(:mjolnir, :btrfs_root, previous)
      File.rm_rf(root)
    end)

    %{root: root, vm_id: "vm-#{System.unique_integer([:positive])}"}
  end

  test "200-equivalent accept fsyncs a file named by the producer id", %{vm_id: vm_id} do
    assert {:ok, %{message_id: "turn-1", status: :queued}} =
             Mailbox.accept(vm_id, "external", %{"type" => "turn"}, id: "turn-1")

    path = Path.join([Application.get_env(:mjolnir, :btrfs_root), "@mail", vm_id, "turn-1.json"])
    assert File.exists?(path)
    {:ok, rec} = Jason.decode(File.read!(path))
    assert rec["payload"]["type"] == "turn"
    assert rec["seq"] == 1
  end

  test "same id is a duplicate even after ack", %{vm_id: vm_id} do
    assert {:ok, %{status: :queued}} =
             Mailbox.accept(vm_id, "external", %{"n" => 1}, id: "same")

    assert {:ok, %{status: :duplicate}} =
             Mailbox.accept(vm_id, "external", %{"n" => 2}, id: "same")

    :ok = Mailbox.ack(vm_id, "same")

    assert {:ok, %{status: :duplicate}} =
             Mailbox.accept(vm_id, "external", %{"n" => 3}, id: "same")

    assert Mailbox.list_unacked(vm_id) == []
  end

  test "omitted id is host-generated and a retry without it is a new message", %{vm_id: vm_id} do
    {:ok, %{message_id: a, status: :queued}} = Mailbox.accept(vm_id, "external", %{"n" => 1})
    {:ok, %{message_id: b, status: :queued}} = Mailbox.accept(vm_id, "external", %{"n" => 1})
    assert a != b
    assert length(Mailbox.list_unacked(vm_id)) == 2
  end

  test "invalid id is refused", %{vm_id: vm_id} do
    assert {:error, :invalid_message_id} =
             Mailbox.accept(vm_id, "external", %{}, id: "../escape")
  end

  test "application ack tombstones; vsock-layer is not involved", %{vm_id: vm_id} do
    {:ok, _} = Mailbox.accept(vm_id, "external", %{}, id: "m1")
    assert [%{"message_id" => "m1"}] = Mailbox.list_unacked(vm_id)
    assert :ok = Mailbox.ack(vm_id, "m1")
    assert Mailbox.list_unacked(vm_id) == []

    acked =
      Path.join([
        Application.get_env(:mjolnir, :btrfs_root),
        "@mail",
        vm_id,
        "acked",
        "m1.json"
      ])

    assert File.exists?(acked)
  end

  test "drop_mailbox bounces unacked mail", %{vm_id: vm_id} do
    {:ok, _} = Mailbox.accept(vm_id, "external", %{}, id: "gone")
    :ok = Mailbox.drop_mailbox(vm_id)
    assert Mailbox.list_unacked(vm_id) == []

    bounced =
      Path.join([
        Application.get_env(:mjolnir, :btrfs_root),
        "@mail",
        vm_id,
        "bounced",
        "gone.json"
      ])

    assert File.exists?(bounced)
  end

  test "give-up on max attempts", %{vm_id: vm_id} do
    previous = Application.get_env(:mjolnir, :mailbox_max_attempts)
    Application.put_env(:mjolnir, :mailbox_max_attempts, 2)
    on_exit(fn -> Application.put_env(:mjolnir, :mailbox_max_attempts, previous) end)

    {:ok, _} = Mailbox.accept(vm_id, "external", %{}, id: "try")
    assert :ok = Mailbox.record_attempt(vm_id, "try")
    assert :bounced = Mailbox.record_attempt(vm_id, "try")
    assert Mailbox.list_unacked(vm_id) == []
  end

  test "unacked mail survives a dormant transition; nothing take-then-sends", %{vm_id: vm_id} do
    :ok = Mjolnir.DormantRegistry.register(vm_id, "snap-done", %{})
    on_exit(fn -> Mjolnir.DormantRegistry.unregister(vm_id) end)

    assert {:ok, %{status: :queued}} =
             Mailbox.accept(vm_id, "external", %{"type" => "turn"}, id: "during-done")

    assert [%{"message_id" => "during-done"}] = Mailbox.list_unacked(vm_id)
    # Restore used to take_pending_messages then vsock-cast, clearing the only
    # copy. The spool file is the copy; DormantRegistry is not the queue.
    assert [] = Mjolnir.DormantRegistry.take_pending_messages(vm_id)
    assert [%{"message_id" => "during-done"}] = Mailbox.list_unacked(vm_id)
  end

  test "guest send_message message_id is Mailbox.accept id", %{vm_id: vm_id} do
    assert [id: "turn-1"] =
             Mjolnir.Vsock.Connection.guest_send_opts(%{"message_id" => "turn-1"})

    assert [] = Mjolnir.Vsock.Connection.guest_send_opts(%{"id" => "corr-only"})

    assert {:ok, %{message_id: "turn-1", status: :queued}} =
             Mailbox.accept(vm_id, "source-vm", %{"n" => 1}, id: "turn-1")

    assert {:ok, %{status: :duplicate}} =
             Mailbox.accept(vm_id, "source-vm", %{"n" => 1}, id: "turn-1")
  end
end
