defmodule Mjolnir.Policy.VMTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Policy.VM

  @owner_user %{user_id: "user-123"}
  @other_user %{user_id: "user-456"}
  @localhost %{user_id: "localhost"}
  @owned_vm %{owner_id: "user-123"}
  @other_vm %{owner_id: "user-456"}
  @legacy_vm %{owner_id: nil}

  describe "localhost bypass" do
    test "localhost can perform any action on any resource" do
      for action <- [:spawn, :list, :read, :exec, :stop, :snapshot, :ticket, :pty, :message] do
        assert :ok = VM.authorize(action, @localhost, @owned_vm),
               "localhost should be allowed #{action} on owned VM"

        assert :ok = VM.authorize(action, @localhost, @other_vm),
               "localhost should be allowed #{action} on other VM"

        assert :ok = VM.authorize(action, @localhost, @legacy_vm),
               "localhost should be allowed #{action} on legacy VM"

        assert :ok = VM.authorize(action, @localhost, nil),
               "localhost should be allowed #{action} on nil resource"
      end
    end
  end

  describe "collection actions (spawn, list)" do
    test "any authenticated user can spawn" do
      assert :ok = VM.authorize(:spawn, @owner_user, nil)
      assert :ok = VM.authorize(:spawn, @other_user, nil)
    end

    test "any authenticated user can list" do
      assert :ok = VM.authorize(:list, @owner_user, nil)
      assert :ok = VM.authorize(:list, @other_user, nil)
    end
  end

  describe "resource actions - owner access" do
    for action <- [:read, :exec, :stop, :snapshot, :ticket, :pty, :message] do
      test "owner can #{action} their own VM" do
        assert :ok = VM.authorize(unquote(action), @owner_user, @owned_vm)
      end
    end
  end

  describe "resource actions - non-owner denied" do
    for action <- [:read, :exec, :stop, :snapshot, :ticket, :pty, :message] do
      test "non-owner denied #{action}" do
        assert :error = VM.authorize(unquote(action), @other_user, @owned_vm)
      end
    end
  end

  describe "legacy VMs (nil owner_id)" do
    for action <- [:read, :exec, :stop, :snapshot, :ticket, :pty, :message] do
      test "regular user denied #{action} on legacy VM" do
        assert :error = VM.authorize(unquote(action), @owner_user, @legacy_vm)
      end
    end
  end

  describe "unauthenticated (nil user)" do
    test "nil user is denied all actions" do
      for action <- [:spawn, :list, :read, :exec, :stop, :snapshot, :ticket, :pty, :message] do
        assert :error = VM.authorize(action, nil, @owned_vm),
               "nil user should be denied #{action}"
      end
    end
  end

  describe "default deny" do
    test "unknown action is denied" do
      assert :error = VM.authorize(:unknown_action, @owner_user, @owned_vm)
    end

    test "empty user map is denied" do
      assert :error = VM.authorize(:read, %{}, @owned_vm)
    end
  end
end
