defmodule Mjolnir.StateStoreTest do
  use ExUnit.Case, async: false

  alias Mjolnir.StateStore
  alias Mjolnir.StateStore.Record

  setup do
    # The application starts a single StateStore under supervision; we reuse
    # it with a per-test state_dir so we don't race with the supervisor
    # restarting it if we tried to stop it ourselves.
    tmp =
      Path.join([
        System.tmp_dir!(),
        "mjolnir-state-test",
        "#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(tmp)
    File.mkdir_p!(Path.join(tmp, "quarantine"))

    prev = Application.get_env(:mjolnir, :state_dir)
    Application.put_env(:mjolnir, :state_dir, tmp)
    :ok = StateStore.reload()

    on_exit(fn ->
      File.rm_rf!(tmp)
      if prev, do: Application.put_env(:mjolnir, :state_dir, prev)
      :ok = StateStore.reload()
    end)

    {:ok, state_dir: tmp}
  end

  describe "Record JSON round-trip" do
    test "to_json/from_json is lossless for a minimal record" do
      r =
        Record.new("abc", :running,
          created_at: ~U[2026-04-21 10:00:00Z],
          spawn_config: %{"vcpus" => 2, "memory_mb" => 512}
        )

      assert {:ok, back} = Record.from_json(Record.to_json(r))
      assert back.uuid == "abc"
      assert back.intent == :running
      assert back.created_at == ~U[2026-04-21 10:00:00Z]
      assert back.spawn_config == %{"vcpus" => 2, "memory_mb" => 512}
      assert back.last_boot_at == nil
      assert back.dormant == nil
    end

    test "to_json/from_json preserves all optional fields" do
      r =
        Record.new("xyz", :dormant,
          created_at: ~U[2026-04-21 10:00:00Z],
          last_boot_at: ~U[2026-04-21 11:00:00Z],
          identity: %{"hostname" => "vm-xyz", "iroh_node_id" => "abc123"},
          dormant: %{"snapshot_name" => "snap-1", "wake_on_message" => true},
          runtime: %{"ch_api_socket" => "/var/run/mjolnir/xyz.sock"}
        )

      assert {:ok, back} = Record.from_json(Record.to_json(r))
      assert back.last_boot_at == ~U[2026-04-21 11:00:00Z]
      assert back.identity["hostname"] == "vm-xyz"
      assert back.dormant["snapshot_name"] == "snap-1"
      assert back.runtime["ch_api_socket"] == "/var/run/mjolnir/xyz.sock"
    end

    test "round-trips the :failed intent (mjolnir-5fu retirement)" do
      r =
        Record.new("ghost", :failed,
          created_at: ~U[2026-06-08 10:00:00Z],
          runtime: %{"resume_failures" => 11, "first_failure_at" => "2026-06-08T10:00:00Z"}
        )

      assert {:ok, back} = Record.from_json(Record.to_json(r))
      assert back.intent == :failed
      assert back.runtime["resume_failures"] == 11
    end

    test "rejects missing schema_version" do
      json = Jason.encode!(%{"uuid" => "x", "intent" => "running"})
      assert {:error, :schema_version_mismatch} = Record.from_json(json)
    end

    test "rejects wrong schema_version" do
      json =
        Jason.encode!(%{
          "schema_version" => 999,
          "uuid" => "x",
          "intent" => "running",
          "created_at" => "2026-04-21T10:00:00Z"
        })

      assert {:error, :schema_version_mismatch} = Record.from_json(json)
    end

    test "rejects invalid intent" do
      json =
        Jason.encode!(%{
          "schema_version" => 1,
          "uuid" => "x",
          "intent" => "zombie",
          "created_at" => "2026-04-21T10:00:00Z"
        })

      assert {:error, :invalid_intent} = Record.from_json(json)
    end

    test "rejects malformed JSON" do
      assert {:error, :invalid_json} = Record.from_json("not json")
      assert {:error, :invalid_json} = Record.from_json("[]")
    end

    test "rejects missing required field" do
      json = Jason.encode!(%{"schema_version" => 1, "intent" => "running"})
      assert {:error, :missing_field} = Record.from_json(json)
    end
  end

  describe "put/get round-trip" do
    test "put then get returns the same record" do
      r = Record.new("uuid-1", :running, spawn_config: %{"memory_mb" => 1024})
      assert :ok = StateStore.put(r)
      assert {:ok, back} = StateStore.get("uuid-1")
      assert back.uuid == "uuid-1"
      assert back.intent == :running
      assert back.spawn_config == %{"memory_mb" => 1024}
    end

    test "get on unknown uuid returns :not_found" do
      assert :not_found = StateStore.get("does-not-exist")
    end

    test "put overwrites existing record" do
      r1 = Record.new("uuid-2", :running)
      r2 = Record.new("uuid-2", :dormant, dormant: %{"snapshot_name" => "s1"})
      assert :ok = StateStore.put(r1)
      assert :ok = StateStore.put(r2)
      assert {:ok, back} = StateStore.get("uuid-2")
      assert back.intent == :dormant
      assert back.dormant["snapshot_name"] == "s1"
    end
  end

  describe "atomic write" do
    test "put produces the final file and no lingering .tmp", %{state_dir: dir} do
      r = Record.new("uuid-atomic", :running)
      assert :ok = StateStore.put(r)

      assert File.exists?(Path.join(dir, "uuid-atomic.json"))
      refute File.exists?(Path.join(dir, "uuid-atomic.json.tmp"))
    end

    test "file content is valid JSON parseable back to the same record", %{state_dir: dir} do
      r = Record.new("uuid-disk", :running, identity: %{"hostname" => "vm-disk"})
      assert :ok = StateStore.put(r)

      bin = File.read!(Path.join(dir, "uuid-disk.json"))
      assert {:ok, back} = Record.from_json(bin)
      assert back.uuid == "uuid-disk"
      assert back.identity["hostname"] == "vm-disk"
    end
  end

  describe "delete" do
    test "removes file and cache" do
      r = Record.new("uuid-del", :running)
      assert :ok = StateStore.put(r)
      assert {:ok, _} = StateStore.get("uuid-del")
      assert :ok = StateStore.delete("uuid-del")
      assert :not_found = StateStore.get("uuid-del")
    end

    test "is idempotent for unknown uuid" do
      assert :ok = StateStore.delete("does-not-exist")
    end

    test "file is gone from disk", %{state_dir: dir} do
      r = Record.new("uuid-del-2", :running)
      assert :ok = StateStore.put(r)
      assert :ok = StateStore.delete("uuid-del-2")
      refute File.exists?(Path.join(dir, "uuid-del-2.json"))
    end
  end

  describe "list / list_by_intent" do
    test "list returns all records" do
      assert StateStore.list() == []

      StateStore.put(Record.new("a", :running))
      StateStore.put(Record.new("b", :dormant))
      StateStore.put(Record.new("c", :stopped))

      uuids = StateStore.list() |> Enum.map(& &1.uuid) |> Enum.sort()
      assert uuids == ["a", "b", "c"]
    end

    test "list_by_intent filters correctly" do
      StateStore.put(Record.new("r1", :running))
      StateStore.put(Record.new("r2", :running))
      StateStore.put(Record.new("d1", :dormant))
      StateStore.put(Record.new("s1", :stopped))

      running = StateStore.list_by_intent(:running) |> Enum.map(& &1.uuid) |> Enum.sort()
      assert running == ["r1", "r2"]

      assert [%Record{uuid: "d1"}] = StateStore.list_by_intent(:dormant)
      assert [%Record{uuid: "s1"}] = StateStore.list_by_intent(:stopped)
    end
  end

  describe "reload from disk" do
    test "picks up files written outside the GenServer", %{state_dir: dir} do
      # Simulate a file placed on disk directly (e.g. by a migration)
      r = Record.new("external", :running)
      File.write!(Path.join(dir, "external.json"), Record.to_json(r))

      assert :not_found = StateStore.get("external")
      assert :ok = StateStore.reload()
      assert {:ok, back} = StateStore.get("external")
      assert back.uuid == "external"
    end

    test "clears ETS before reloading", %{state_dir: dir} do
      StateStore.put(Record.new("ghost", :running))
      File.rm!(Path.join(dir, "ghost.json"))

      assert :ok = StateStore.reload()
      assert :not_found = StateStore.get("ghost")
    end
  end

  describe "quarantine" do
    test "bad JSON files are moved to quarantine/, not loaded", %{state_dir: dir} do
      File.write!(Path.join(dir, "bogus.json"), "not valid json at all")

      assert :ok = StateStore.reload()
      assert :not_found = StateStore.get("bogus")
      refute File.exists?(Path.join(dir, "bogus.json"))

      quarantined = Path.join(dir, "quarantine") |> File.ls!()
      assert Enum.any?(quarantined, &String.starts_with?(&1, "bogus.json.bad-"))
    end

    test "schema version mismatch is quarantined", %{state_dir: dir} do
      bad =
        Jason.encode!(%{
          "schema_version" => 42,
          "uuid" => "future",
          "intent" => "running",
          "created_at" => "2026-04-21T10:00:00Z"
        })

      File.write!(Path.join(dir, "future.json"), bad)
      assert :ok = StateStore.reload()
      assert :not_found = StateStore.get("future")

      quarantined = Path.join(dir, "quarantine") |> File.ls!()
      assert Enum.any?(quarantined, &String.starts_with?(&1, "future.json.bad-"))
    end

    test "valid records loaded alongside quarantined ones", %{state_dir: dir} do
      good = Record.new("good", :running)
      File.write!(Path.join(dir, "good.json"), Record.to_json(good))
      File.write!(Path.join(dir, "bad.json"), "garbage")

      assert :ok = StateStore.reload()
      assert {:ok, _} = StateStore.get("good")
      assert :not_found = StateStore.get("bad")
    end
  end
end
