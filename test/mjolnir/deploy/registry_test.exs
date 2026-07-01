defmodule Mjolnir.Deploy.RegistryTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Deploy.Registry
  alias Mjolnir.Deploy.Registry.Entry

  # Each test gets a unique tmp dir and a uniquely named Registry instance.
  # Because the ETS table is private (anonymous), multiple instances can run
  # concurrently without clashing — hence async: true.
  setup do
    dir =
      Path.join([
        System.tmp_dir!(),
        "mjolnir-deploy-registry-test",
        "#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    name = :"deploy_registry_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised!({Registry, [name: name, dir: dir]}) |> then(&{:ok, &1})

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir, name: name, pid: pid}
  end

  describe "put/get round-trip" do
    test "put then get returns the same entry", %{name: name} do
      assert {:ok, entry} =
               Registry.put(name, "my-app", %{
                 release_snapshot: "snap-abc",
                 service_vm_id: "vm-123",
                 url: "https://my-app.vm.example.com"
               })

      assert entry.app_name == "my-app"
      assert entry.release_snapshot == "snap-abc"
      assert entry.service_vm_id == "vm-123"
      assert entry.url == "https://my-app.vm.example.com"
      assert is_integer(entry.updated_at)

      assert {:ok, fetched} = Registry.get(name, "my-app")
      assert fetched.app_name == "my-app"
      assert fetched.release_snapshot == "snap-abc"
      assert fetched.service_vm_id == "vm-123"
    end

    test "updated_at is stamped automatically", %{name: name} do
      before = System.os_time(:second)
      {:ok, entry} = Registry.put(name, "my-app", %{release_snapshot: "snap-1"})
      after_put = System.os_time(:second)

      assert entry.updated_at >= before
      assert entry.updated_at <= after_put
    end

    test "get returns error for unknown app", %{name: name} do
      assert {:error, :not_found} = Registry.get(name, "no-such-app")
    end

    test "nil fields are preserved", %{name: name} do
      {:ok, entry} = Registry.put(name, "bare-app", %{release_snapshot: "snap-x"})
      assert entry.service_vm_id == nil
      assert entry.url == nil
    end
  end

  describe "put upsert" do
    test "second put on same app_name overwrites", %{name: name} do
      Registry.put(name, "app", %{release_snapshot: "snap-1", url: "https://old.example.com"})

      :timer.sleep(1)

      {:ok, entry2} =
        Registry.put(name, "app", %{release_snapshot: "snap-2", url: "https://new.example.com"})

      assert entry2.release_snapshot == "snap-2"
      assert entry2.url == "https://new.example.com"

      {:ok, fetched} = Registry.get(name, "app")
      assert fetched.release_snapshot == "snap-2"
    end

    test "upsert updates updated_at", %{name: name} do
      {:ok, e1} = Registry.put(name, "app", %{release_snapshot: "snap-1"})
      :timer.sleep(1100)
      {:ok, e2} = Registry.put(name, "app", %{release_snapshot: "snap-2"})

      assert e2.updated_at >= e1.updated_at
    end
  end

  describe "list" do
    test "returns empty list initially", %{name: name} do
      assert Registry.list(name) == []
    end

    test "returns all entries", %{name: name} do
      Registry.put(name, "app-a", %{release_snapshot: "snap-a"})
      Registry.put(name, "app-b", %{release_snapshot: "snap-b"})
      Registry.put(name, "app-c", %{release_snapshot: "snap-c"})

      names = Registry.list(name) |> Enum.map(& &1.app_name) |> Enum.sort()
      assert names == ["app-a", "app-b", "app-c"]
    end
  end

  describe "delete" do
    test "removes from cache", %{name: name} do
      Registry.put(name, "app", %{release_snapshot: "snap-1"})
      assert {:ok, _} = Registry.get(name, "app")

      assert :ok = Registry.delete(name, "app")
      assert {:error, :not_found} = Registry.get(name, "app")
    end

    test "removes file from disk", %{name: name, dir: dir} do
      Registry.put(name, "my-app", %{release_snapshot: "snap-1"})
      assert File.exists?(Path.join(dir, "my-app.json"))

      Registry.delete(name, "my-app")
      refute File.exists?(Path.join(dir, "my-app.json"))
    end

    test "is idempotent for unknown app", %{name: name} do
      assert :ok = Registry.delete(name, "no-such-app")
    end
  end

  describe "atomic write" do
    test "produces final file with no lingering .tmp", %{name: name, dir: dir} do
      Registry.put(name, "atomicapp", %{release_snapshot: "snap-1"})
      assert File.exists?(Path.join(dir, "atomicapp.json"))
      refute File.exists?(Path.join(dir, "atomicapp.json.tmp"))
    end

    test "file content is valid JSON parseable back to the same entry", %{name: name, dir: dir} do
      Registry.put(name, "json-app", %{
        release_snapshot: "snap-99",
        service_vm_id: "vm-xyz",
        url: "https://json-app.example.com"
      })

      bin = File.read!(Path.join(dir, "json-app.json"))
      assert {:ok, map} = Jason.decode(bin)
      assert map["app_name"] == "json-app"
      assert map["release_snapshot"] == "snap-99"
      assert map["service_vm_id"] == "vm-xyz"
    end
  end

  describe "persistence (reload from disk)" do
    test "entries survive a stop+restart of the GenServer", %{name: _name, dir: dir} do
      name1 = :"registry_persist_#{System.unique_integer([:positive])}"
      {:ok, pid1} = Registry.start_link(name: name1, dir: dir)

      Registry.put(name1, "persistent-app", %{
        release_snapshot: "snap-durable",
        service_vm_id: "vm-abc",
        url: "https://persistent.example.com"
      })

      GenServer.stop(pid1)

      name2 = :"registry_persist_#{System.unique_integer([:positive])}"
      {:ok, pid2} = Registry.start_link(name: name2, dir: dir)

      assert {:ok, entry} = Registry.get(name2, "persistent-app")
      assert entry.release_snapshot == "snap-durable"
      assert entry.service_vm_id == "vm-abc"
      assert entry.url == "https://persistent.example.com"

      GenServer.stop(pid2)
    end

    test "multiple entries all reload correctly", %{name: _name, dir: dir} do
      name1 = :"registry_multi_#{System.unique_integer([:positive])}"
      {:ok, pid1} = Registry.start_link(name: name1, dir: dir)

      Registry.put(name1, "app-1", %{release_snapshot: "snap-1"})
      Registry.put(name1, "app-2", %{release_snapshot: "snap-2"})
      Registry.put(name1, "app-3", %{release_snapshot: "snap-3"})

      GenServer.stop(pid1)

      name2 = :"registry_multi_#{System.unique_integer([:positive])}"
      {:ok, pid2} = Registry.start_link(name: name2, dir: dir)

      names = Registry.list(name2) |> Enum.map(& &1.app_name) |> Enum.sort()
      assert names == ["app-1", "app-2", "app-3"]

      GenServer.stop(pid2)
    end
  end

  describe "fault-tolerant init" do
    test "malformed JSON file is skipped; other entries still load", %{dir: dir} do
      # Write a good entry directly to disk
      good_json =
        Jason.encode!(%{
          "app_name" => "good-app",
          "release_snapshot" => "snap-good",
          "service_vm_id" => nil,
          "url" => nil,
          "updated_at" => System.os_time(:second)
        })

      File.write!(Path.join(dir, "good-app.json"), good_json)
      File.write!(Path.join(dir, "bad-file.json"), "this is not valid json!!!{{{")

      name = :"registry_fault_#{System.unique_integer([:positive])}"
      {:ok, pid} = Registry.start_link(name: name, dir: dir)

      # Bad file did not crash init
      assert {:ok, entry} = Registry.get(name, "good-app")
      assert entry.release_snapshot == "snap-good"

      # Bad file did not load
      assert {:error, :not_found} = Registry.get(name, "bad-file")

      GenServer.stop(pid)
    end

    test "missing required fields in JSON file are skipped", %{dir: dir} do
      # Missing release_snapshot field
      bad_json =
        Jason.encode!(%{
          "app_name" => "incomplete-app",
          "updated_at" => System.os_time(:second)
        })

      File.write!(Path.join(dir, "incomplete-app.json"), bad_json)

      name = :"registry_missing_#{System.unique_integer([:positive])}"
      {:ok, pid} = Registry.start_link(name: name, dir: dir)

      assert {:error, :not_found} = Registry.get(name, "incomplete-app")

      GenServer.stop(pid)
    end
  end

  describe "Entry struct" do
    test "has the expected fields" do
      entry = %Entry{
        app_name: "test",
        release_snapshot: "snap-1",
        updated_at: 0
      }

      assert entry.app_name == "test"
      assert entry.release_snapshot == "snap-1"
      assert entry.service_vm_id == nil
      assert entry.url == nil
      assert entry.custom_domain == nil
      assert entry.port == nil
      assert entry.updated_at == 0
    end
  end

  describe "custom_domain + port (gateway routing)" do
    test "put then get round-trips custom_domain and port", %{name: name} do
      assert {:ok, entry} =
               Registry.put(name, "zine", %{
                 release_snapshot: "snap-z",
                 service_vm_id: "vm-z",
                 custom_domain: "zine.identikey.io",
                 port: 3000
               })

      assert entry.custom_domain == "zine.identikey.io"
      assert entry.port == 3000

      assert {:ok, fetched} = Registry.get(name, "zine")
      assert fetched.custom_domain == "zine.identikey.io"
      assert fetched.port == 3000
    end

    test "default nil when not provided", %{name: name} do
      {:ok, entry} = Registry.put(name, "bare", %{release_snapshot: "snap-1"})
      assert entry.custom_domain == nil
      assert entry.port == nil
    end

    test "new fields are persisted to JSON and reload from disk", %{dir: dir} do
      name1 = :"registry_newfields_#{System.unique_integer([:positive])}"
      {:ok, pid1} = Registry.start_link(name: name1, dir: dir)

      Registry.put(name1, "domapp", %{
        release_snapshot: "snap-1",
        service_vm_id: "vm-1",
        custom_domain: "app.identikey.io",
        port: 8080
      })

      bin = File.read!(Path.join(dir, "domapp.json"))
      assert {:ok, map} = Jason.decode(bin)
      assert map["custom_domain"] == "app.identikey.io"
      assert map["port"] == 8080

      GenServer.stop(pid1)

      name2 = :"registry_newfields_#{System.unique_integer([:positive])}"
      {:ok, pid2} = Registry.start_link(name: name2, dir: dir)
      assert {:ok, entry} = Registry.get(name2, "domapp")
      assert entry.custom_domain == "app.identikey.io"
      assert entry.port == 8080
      GenServer.stop(pid2)
    end

    test "old JSON file without custom_domain/port still loads (backward compat)", %{dir: dir} do
      # Simulate a pre-feature record: no custom_domain / port keys.
      old_json =
        Jason.encode!(%{
          "app_name" => "legacy-app",
          "release_snapshot" => "snap-old",
          "service_vm_id" => "vm-old",
          "url" => "https://legacy.example.com",
          "updated_at" => System.os_time(:second)
        })

      File.write!(Path.join(dir, "legacy-app.json"), old_json)

      name = :"registry_legacy_#{System.unique_integer([:positive])}"
      {:ok, pid} = Registry.start_link(name: name, dir: dir)

      assert {:ok, entry} = Registry.get(name, "legacy-app")
      assert entry.release_snapshot == "snap-old"
      assert entry.service_vm_id == "vm-old"
      assert entry.custom_domain == nil
      assert entry.port == nil

      GenServer.stop(pid)
    end
  end
end
