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

    test "reports an unknown but well-formed schema_version distinctly" do
      # Distinct from a *malformed* version, because the correct response differs:
      # a file from the future is intact and must not be quarantined.
      json =
        Jason.encode!(%{
          "schema_version" => 999,
          "uuid" => "x",
          "intent" => "running",
          "created_at" => "2026-04-21T10:00:00Z"
        })

      assert {:error, {:unsupported_schema_version, 999}} = Record.from_json(json)
    end

    test "rejects a malformed schema_version" do
      json =
        Jason.encode!(%{
          "schema_version" => "not-a-version",
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

    test "a malformed schema_version is quarantined", %{state_dir: dir} do
      bad =
        Jason.encode!(%{
          "schema_version" => "forty-two",
          "uuid" => "garbled",
          "intent" => "running",
          "created_at" => "2026-04-21T10:00:00Z"
        })

      File.write!(Path.join(dir, "garbled.json"), bad)
      assert :ok = StateStore.reload()
      assert :not_found = StateStore.get("garbled")

      quarantined = Path.join(dir, "quarantine") |> File.ls!()
      assert Enum.any?(quarantined, &String.starts_with?(&1, "garbled.json.bad-"))
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

  describe "metadata" do
    test "round-trips through JSON and defaults to empty" do
      r = Record.new("m1", :running, metadata: %{"buzz.managed-by" => "buzz-backend-mjolnir"})
      assert {:ok, back} = Record.from_json(Record.to_json(r))
      assert back.metadata == %{"buzz.managed-by" => "buzz-backend-mjolnir"}

      assert {:ok, plain} = Record.from_json(Record.to_json(Record.new("m2", :running)))
      assert plain.metadata == %{}
    end

    test "coerces non-string keys and values at the boundary" do
      r = Record.new("m3", :running, metadata: %{:atom_key => 42})
      assert r.metadata == %{"atom_key" => "42"}
    end

    test "list_by_metadata requires every pair in the selector to match" do
      :ok = StateStore.put(Record.new("s1", :running, metadata: %{"app" => "buzz", "id" => "a"}))
      :ok = StateStore.put(Record.new("s2", :running, metadata: %{"app" => "buzz", "id" => "b"}))
      :ok = StateStore.put(Record.new("s3", :running, metadata: %{"app" => "other"}))

      assert StateStore.list_by_metadata(%{"app" => "buzz"}) |> Enum.map(& &1.uuid) |> Enum.sort() ==
               ["s1", "s2"]

      assert StateStore.list_by_metadata(%{"app" => "buzz", "id" => "b"}) |> Enum.map(& &1.uuid) ==
               ["s2"]

      assert StateStore.list_by_metadata(%{"app" => "buzz", "id" => "zzz"}) == []
    end

    test "an empty selector matches everything" do
      :ok = StateStore.put(Record.new("e1", :running))
      assert length(StateStore.list_by_metadata(%{})) == length(StateStore.list())
    end

    test "merge_metadata adds keys without dropping existing ones" do
      :ok = StateStore.put(Record.new("mm", :running, metadata: %{"keep" => "yes"}))

      assert {:ok, stored} = StateStore.merge_metadata("mm", %{"added" => "1"})
      assert stored.metadata == %{"keep" => "yes", "added" => "1"}

      assert {:ok, reread} = StateStore.get("mm")
      assert reread.metadata == %{"keep" => "yes", "added" => "1"}
    end

    test "merge_metadata on an unknown uuid is :not_found" do
      assert :not_found = StateStore.merge_metadata("nope", %{"a" => "b"})
    end

    test "a rebuilt record without metadata does not erase existing labels" do
      # `Mjolnir.VM.build_running_record/1` constructs a fresh struct on every
      # persist. Without carry-forward, every VM boot would silently strip the
      # labels an orchestrator uses to find its own VMs.
      :ok = StateStore.put(Record.new("carry", :running, metadata: %{"owner" => "buzz"}))
      :ok = StateStore.put(Record.new("carry", :running))

      assert {:ok, record} = StateStore.get("carry")
      assert record.metadata == %{"owner" => "buzz"}
    end

    test "explicitly passed metadata replaces the previous set" do
      :ok = StateStore.put(Record.new("replace", :running, metadata: %{"a" => "1"}))
      :ok = StateStore.put(Record.new("replace", :running, metadata: %{"b" => "2"}))

      assert {:ok, record} = StateStore.get("replace")
      assert record.metadata == %{"b" => "2"}
    end
  end

  describe "generation" do
    test "starts at 1 and increments on every put" do
      :ok = StateStore.put(Record.new("g", :running))
      assert {:ok, %{generation: 1}} = StateStore.get("g")

      :ok = StateStore.put(Record.new("g", :running))
      assert {:ok, %{generation: 2}} = StateStore.get("g")

      :ok = StateStore.put(Record.new("g", :dormant))
      assert {:ok, %{generation: 3}} = StateStore.get("g")
    end

    test "is owned by the store, so a stale caller cannot reset it" do
      :ok = StateStore.put(Record.new("owned", :running))
      :ok = StateStore.put(Record.new("owned", :running))
      assert {:ok, %{generation: 2}} = StateStore.get("owned")

      # A caller holding a struct from before — the shape every rebuild-from-live-state
      # caller has. If this reset to 1, a fenced delete would pass against a stale read.
      stale = %{Record.new("owned", :running) | generation: 1}
      :ok = StateStore.put(stale)
      assert {:ok, %{generation: 3}} = StateStore.get("owned")
    end

    test "merge_metadata bumps it too" do
      :ok = StateStore.put(Record.new("gm", :running))
      assert {:ok, %{generation: 2}} = StateStore.merge_metadata("gm", %{"k" => "v"})
    end

    test "survives a reload from disk" do
      :ok = StateStore.put(Record.new("persisted", :running, metadata: %{"a" => "b"}))
      :ok = StateStore.put(Record.new("persisted", :running))
      :ok = StateStore.reload()

      assert {:ok, record} = StateStore.get("persisted")
      assert record.generation == 2
      assert record.metadata == %{"a" => "b"}
    end
  end

  describe "delete_if_match (compare-and-delete fencing)" do
    test "deletes when the generation matches" do
      :ok = StateStore.put(Record.new("f1", :running))
      assert {:ok, %{generation: gen}} = StateStore.get("f1")

      assert :ok = StateStore.delete_if_match("f1", gen)
      assert :not_found = StateStore.get("f1")
    end

    test "refuses with :conflict when the record moved since it was read" do
      :ok = StateStore.put(Record.new("f2", :running))
      assert {:ok, %{generation: observed}} = StateStore.get("f2")

      # Someone else writes between our read and our delete.
      :ok = StateStore.put(Record.new("f2", :dormant))

      assert {:error, :conflict} = StateStore.delete_if_match("f2", observed)
      assert {:ok, _still_there} = StateStore.get("f2")
    end

    test "delete-of-absent is success, so a retried delete is not an error" do
      assert :ok = StateStore.delete_if_match("never-existed", 1)
    end

    test "removes the file from disk, not just the cache", %{state_dir: dir} do
      :ok = StateStore.put(Record.new("f3", :running))
      assert File.exists?(Path.join(dir, "f3.json"))

      assert {:ok, %{generation: gen}} = StateStore.get("f3")
      assert :ok = StateStore.delete_if_match("f3", gen)
      refute File.exists?(Path.join(dir, "f3.json"))
    end
  end

  describe "schema v1 -> v2 migration" do
    test "a v1 file loads instead of being quarantined", %{state_dir: dir} do
      # Quarantine is for corrupt files. Quarantining every record on a server
      # during a deploy would be an outage, not a safety measure.
      v1 =
        Jason.encode!(%{
          "schema_version" => 1,
          "uuid" => "legacy",
          "intent" => "running",
          "created_at" => "2026-04-21T10:00:00Z",
          "spawn_config" => %{"vcpus" => 2},
          "identity" => %{},
          "runtime" => %{}
        })

      File.write!(Path.join(dir, "legacy.json"), v1)
      :ok = StateStore.reload()

      assert {:ok, record} = StateStore.get("legacy")
      assert record.spawn_config == %{"vcpus" => 2}
      assert record.metadata == %{}
      assert record.generation == 1
      refute File.exists?(Path.join([dir, "quarantine", "legacy.json.bad"]))
    end

    test "a v1 record is rewritten as v2 on its next put", %{state_dir: dir} do
      v1 =
        Jason.encode!(%{
          "schema_version" => 1,
          "uuid" => "upgrade",
          "intent" => "running",
          "created_at" => "2026-04-21T10:00:00Z"
        })

      File.write!(Path.join(dir, "upgrade.json"), v1)
      :ok = StateStore.reload()

      assert {:ok, loaded} = StateStore.get("upgrade")
      :ok = StateStore.put(loaded)

      on_disk = Path.join(dir, "upgrade.json") |> File.read!() |> Jason.decode!()
      assert on_disk["schema_version"] == 2
      assert on_disk["generation"] == 2
      assert on_disk["metadata"] == %{}
    end

    test "a malformed generation reads as 1 rather than losing the record" do
      json =
        Jason.encode!(%{
          "schema_version" => 2,
          "uuid" => "weird",
          "intent" => "running",
          "created_at" => "2026-04-21T10:00:00Z",
          "generation" => "not-a-number"
        })

      assert {:ok, record} = Record.from_json(json)
      assert record.generation == 1
    end
  end

  describe "rollback survival (record written by a newer schema version)" do
    defp write_future_record(dir, uuid, version \\ 3) do
      File.write!(
        Path.join(dir, "#{uuid}.json"),
        Jason.encode!(%{
          "schema_version" => version,
          "uuid" => uuid,
          "intent" => "running",
          "created_at" => "2026-08-07T10:00:00Z"
        })
      )
    end

    test "the file is left exactly where it is, not quarantined", %{state_dir: dir} do
      # Quarantine *renames*. Doing it here would mean that rolling forward again
      # could not find the record either — the rollback itself destroys the data.
      write_future_record(dir, "from-the-future")
      assert :ok = StateStore.reload()

      assert File.exists?(Path.join(dir, "from-the-future.json"))
      assert Path.join(dir, "quarantine") |> File.ls!() == []
    end

    test "the record is not served from the cache" do
      # We cannot read it, so we must not pretend to.
      assert :not_found = StateStore.get("from-the-future")
    end

    test "the uuid is reported as unreadable with its version", %{state_dir: dir} do
      write_future_record(dir, "reported", 7)
      assert :ok = StateStore.reload()

      assert %{"reported" => {:unsupported_schema_version, 7}} = StateStore.unreadable()
    end

    test "writes to that uuid are refused rather than clobbering it", %{state_dir: dir} do
      write_future_record(dir, "protected")
      assert :ok = StateStore.reload()

      assert {:error, :record_unreadable} =
               StateStore.put(Record.new("protected", :running))

      assert {:error, :record_unreadable} = StateStore.delete("protected")
      assert {:error, :record_unreadable} = StateStore.delete_if_match("protected", 1)
      assert {:error, :record_unreadable} = StateStore.merge_metadata("protected", %{"a" => "b"})

      # Still intact and still from the future.
      on_disk = Path.join(dir, "protected.json") |> File.read!() |> Jason.decode!()
      assert on_disk["schema_version"] == 3
    end

    test "readable records alongside it still load", %{state_dir: dir} do
      write_future_record(dir, "unreadable-one")
      :ok = StateStore.put(Record.new("readable-one", :running))
      assert :ok = StateStore.reload()

      assert {:ok, _} = StateStore.get("readable-one")
      assert :not_found = StateStore.get("unreadable-one")
      assert Map.has_key?(StateStore.unreadable(), "unreadable-one")
    end

    test "rolling forward recovers the record", %{state_dir: dir} do
      # The whole point: the older binary left the bytes alone, so a build that
      # understands the version reads it back unharmed.
      write_future_record(dir, "recovered")
      assert :ok = StateStore.reload()
      assert :not_found = StateStore.get("recovered")

      # Simulate the newer build: rewrite at a version this one speaks.
      contents = Path.join(dir, "recovered.json") |> File.read!() |> Jason.decode!()

      File.write!(
        Path.join(dir, "recovered.json"),
        Jason.encode!(%{contents | "schema_version" => Record.schema_version()})
      )

      assert :ok = StateStore.reload()
      assert {:ok, record} = StateStore.get("recovered")
      assert record.uuid == "recovered"
      assert StateStore.unreadable() == %{}
    end
  end
end
