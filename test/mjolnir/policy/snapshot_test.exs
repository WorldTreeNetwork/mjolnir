defmodule Mjolnir.Policy.SnapshotTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Policy.Snapshot

  @owner_user %{user_id: "user-123"}
  @other_user %{user_id: "user-456"}
  @localhost %{user_id: "localhost"}
  @owned_snapshot %{owner_id: "user-123", name: "my-snap"}
  @other_snapshot %{owner_id: "user-456", name: "other-snap"}
  @legacy_snapshot %{owner_id: nil, name: "old-snap"}

  describe "localhost bypass" do
    test "localhost can perform any action on any snapshot" do
      for action <- [:list, :read, :create, :delete] do
        assert :ok = Snapshot.authorize(action, @localhost, @owned_snapshot)
        assert :ok = Snapshot.authorize(action, @localhost, @other_snapshot)
        assert :ok = Snapshot.authorize(action, @localhost, @legacy_snapshot)
        assert :ok = Snapshot.authorize(action, @localhost, nil)
      end
    end
  end

  describe "collection actions" do
    test "any authenticated user can list" do
      assert :ok = Snapshot.authorize(:list, @owner_user, nil)
      assert :ok = Snapshot.authorize(:list, @other_user, nil)
    end

    test "any authenticated user can create" do
      assert :ok = Snapshot.authorize(:create, @owner_user, nil)
      assert :ok = Snapshot.authorize(:create, @other_user, nil)
    end
  end

  describe "resource actions - owner access" do
    test "owner can read their snapshot" do
      assert :ok = Snapshot.authorize(:read, @owner_user, @owned_snapshot)
    end

    test "owner can delete their snapshot" do
      assert :ok = Snapshot.authorize(:delete, @owner_user, @owned_snapshot)
    end
  end

  describe "resource actions - non-owner denied" do
    test "non-owner denied read" do
      assert :error = Snapshot.authorize(:read, @other_user, @owned_snapshot)
    end

    test "non-owner denied delete" do
      assert :error = Snapshot.authorize(:delete, @other_user, @owned_snapshot)
    end
  end

  describe "legacy snapshots (nil owner_id)" do
    test "regular user denied read on legacy snapshot" do
      assert :error = Snapshot.authorize(:read, @owner_user, @legacy_snapshot)
    end

    test "regular user denied delete on legacy snapshot" do
      assert :error = Snapshot.authorize(:delete, @owner_user, @legacy_snapshot)
    end
  end

  describe "unauthenticated (nil user)" do
    test "nil user denied all actions" do
      for action <- [:list, :read, :create, :delete] do
        assert :error = Snapshot.authorize(action, nil, @owned_snapshot)
      end
    end
  end

  describe "atom key handling" do
    test "metadata with atom keys works correctly" do
      meta = %{owner_id: "user-123", name: "test", size_bytes: 1024}
      assert :ok = Snapshot.authorize(:read, @owner_user, meta)
      assert :error = Snapshot.authorize(:read, @other_user, meta)
    end
  end

  describe "default deny" do
    test "unknown action denied" do
      assert :error = Snapshot.authorize(:unknown, @owner_user, @owned_snapshot)
    end
  end
end
