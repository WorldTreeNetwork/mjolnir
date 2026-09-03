defmodule Mjolnir.MemorySnapshotTest do
  @moduledoc """
  mjolnir-3y6.3 — the correctness keystone.

  A restored guest's RAM holds a page cache that describes a specific on-disk
  state. Hand it a filesystem that has moved and you get silent corruption, not
  a crash. These tests pin the parts of that guarantee that are decidable
  without a BTRFS host: generation parsing, the drift refusal, and the layout
  rule that keeps CH's writable artifacts out of a read-only subvolume.

  The rule that restore never mounts the live `@vms/<id>` subvolume is
  structural — `prepare_thaw/2` returns a clone path under a *new* vm id — and
  the end-to-end proof (freeze, thaw, marker process still at the same PID)
  needs KVM and lives in the integration suite.
  """
  use ExUnit.Case, async: true

  alias Mjolnir.BTRFS
  alias Mjolnir.MemorySnapshot

  describe "parse_subvolume_info/1 — the pin" do
    @show_output """
    @snapshots/frozen-1
    \tName: \t\t\tfrozen-1
    \tUUID: \t\t\t7bb1f0a2-1c0e-2f4e-9ab1-2f1e5c8d9a01
    \tParent UUID: \t\t3a0c11de-4d5f-6071-8293-a4b5c6d7e8f9
    \tCreation time: \t\t2026-08-13 09:00:00 +0000
    \tSubvolume ID: \t\t312
    \tGeneration: \t\t4471
    \tGen at creation: \t4471
    \tParent ID: \t\t5
    \tFlags: \t\t\treadonly
    """

    test "reads the Generation field" do
      assert {:ok, 4471} = BTRFS.parse_generation(@show_output)
    end

    test "does not match 'Gen at creation'" do
      # The two fields diverge as soon as anything clones from the snapshot, so
      # a regex that matched the wrong line would silently read a stale value.
      drifted = String.replace(@show_output, "Generation: \t\t4471", "Generation: \t\t4600")
      assert {:ok, 4600} = BTRFS.parse_generation(drifted)
    end

    test "reads gen_at_creation and the readonly flag" do
      assert {:ok, info} = BTRFS.parse_subvolume_info(@show_output)
      assert info.generation == 4471
      assert info.gen_at_creation == 4471
      assert info.readonly == true
    end

    test "a writable subvolume reports readonly: false" do
      # `Flags: -` is what btrfs prints for a writable subvolume. A snapshot
      # that is writable cannot pin anything, however unchanged it looks.
      writable = String.replace(@show_output, "Flags: \t\t\treadonly", "Flags: \t\t\t-")
      assert {:ok, %{readonly: false}} = BTRFS.parse_subvolume_info(writable)
    end

    test "gen_at_creation stays put while Generation moves" do
      # This is the whole reason the pin is gen_at_creation. Measured on the
      # host: a snapshot pinned at 208309 read Generation 208311 after ONE
      # successful thaw, because cloning FROM a read-only snapshot updates its
      # root item to list the clone. A Generation-based pin therefore breaks on
      # its own first legitimate use.
      after_clone =
        @show_output
        |> String.replace("Generation: \t\t4471", "Generation: \t\t4473")

      assert {:ok, %{generation: 4473, gen_at_creation: 4471, readonly: true}} =
               BTRFS.parse_subvolume_info(after_clone)
    end

    test "reports a missing field rather than guessing" do
      assert {:error, :generation_not_found} = BTRFS.parse_generation("Name:\tfoo\n")
      assert {:error, :generation_not_found} = BTRFS.parse_generation("")
    end

    test "tolerates leading whitespace variation" do
      assert {:ok, 12} = BTRFS.parse_generation("   Generation:   12   \n")
    end

    test "reads verbatim output from the production host" do
      # Captured from `btrfs subvolume show /var/lib/mjolnir/btrfs/@base/ubuntu-24.04`
      # on 45.76.77.97 (btrfs-progs, Ubuntu noble). Kept byte-for-byte — note the
      # trailing space after each label before the tabs, and the multi-line
      # Snapshot(s) block, both of which a hand-written sample would omit.
      #
      # This subvolume is writable and long-lived, so Generation (207340) has
      # advanced far past Gen at creation (111925). That gap is the point: it is
      # exactly the shape a tampered read-only snapshot takes, and a parser that
      # matched the wrong line would return the stale value and wave it through.
      real = """
      @base/ubuntu-24.04
      \tName: \t\t\tubuntu-24.04
      \tUUID: \t\t\t164f0170-a148-2f41-9b97-bb29ee1d5b5c
      \tParent UUID: \t\t-
      \tReceived UUID: \t\t-
      \tCreation time: \t\t2026-06-23 11:09:39 +0000
      \tSubvolume ID: \t\t411
      \tGeneration: \t\t207340
      \tGen at creation: \t111925
      \tParent ID: \t\t5
      \tTop level ID: \t\t5
      \tFlags: \t\t\t-
      \tSnapshot(s):
      \t\t\t\t@vms/076adf62-b3e1-4696-8427-1b20faf3fd9c
      \t\t\t\t@trash/f740656e-5c6f-4cd4-b6fa-d415d867d257__1786124791__6B0E
      """

      assert {:ok, 207_340} = BTRFS.parse_generation(real)
    end
  end

  describe "memory_dir/1" do
    setup do
      prev = Application.get_env(:mjolnir, :btrfs_root)
      Application.put_env(:mjolnir, :btrfs_root, "/mnt/btrfs")
      on_exit(fn -> if prev, do: Application.put_env(:mjolnir, :btrfs_root, prev) end)
      :ok
    end

    test "sits beside the snapshot subvolume, not inside it" do
      # The subvolume is created read-only so it cannot drift; CH must still be
      # able to write config.json/state.json/memory-ranges. Nesting them would
      # force the subvolume to be writable and undo the pin.
      assert MemorySnapshot.memory_dir("frozen-1") == "/mnt/btrfs/@snapshots/frozen-1.mem"
    end
  end

  describe "memory_snapshot?/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "memsnap-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "@snapshots"))
      prev = Application.get_env(:mjolnir, :btrfs_root)
      Application.put_env(:mjolnir, :btrfs_root, tmp)

      on_exit(fn ->
        File.rm_rf!(tmp)
        if prev, do: Application.put_env(:mjolnir, :btrfs_root, prev)
      end)

      {:ok, root: tmp}
    end

    test "secrets_suspended?/1 is unknown when the sidecar is missing", ctx do
      File.mkdir_p!(Path.join([ctx.root, "@snapshots", "legacy.mem"]))
      File.write!(Path.join([ctx.root, "@snapshots", "legacy.mem", "state.json"]), "{}")
      assert MemorySnapshot.secrets_suspended?("legacy") == :unknown
    end

    test "secrets_suspended?/1 reads the sidecar", ctx do
      dir = Path.join([ctx.root, "@snapshots", "frozen.mem"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "state.json"), "{}")
      File.write!(Path.join(dir, "secrets.json"), ~s({"suspended":true}))
      assert MemorySnapshot.secrets_suspended?("frozen") == true

      File.write!(Path.join(dir, "secrets.json"), ~s({"suspended":false}))
      assert MemorySnapshot.secrets_suspended?("frozen") == false
    end

    test "false when only a filesystem snapshot exists", ctx do
      File.mkdir_p!(Path.join([ctx.root, "@snapshots", "fs-only"]))
      refute MemorySnapshot.memory_snapshot?("fs-only")
    end

    test "true once CH has written state.json", ctx do
      mem = Path.join([ctx.root, "@snapshots", "frozen.mem"])
      File.mkdir_p!(mem)
      File.write!(Path.join(mem, "state.json"), "{}")
      assert MemorySnapshot.memory_snapshot?("frozen")
    end

    test "false for a memory dir that exists but is empty", ctx do
      # A freeze that failed partway leaves a directory behind. Treating its
      # existence as proof would send a caller down the thaw path with no RAM
      # image to restore.
      File.mkdir_p!(Path.join([ctx.root, "@snapshots", "half-written.mem"]))
      refute MemorySnapshot.memory_snapshot?("half-written")
    end

    test "kind/1 and annotate/1 follow the artifacts, not a sidecar claim", ctx do
      File.mkdir_p!(Path.join([ctx.root, "@snapshots", "frozen.mem"]))
      File.write!(Path.join([ctx.root, "@snapshots", "frozen.mem", "state.json"]), "{}")

      assert MemorySnapshot.kind("frozen") == "memory"
      assert MemorySnapshot.kind("ghost") == "filesystem"

      annotated =
        MemorySnapshot.annotate(%{name: "frozen", kind: "filesystem", owner_id: "u"})

      assert annotated.kind == "memory"
    end

    test "delete_snapshot/1 removes the .mem sibling", ctx do
      snap = Path.join([ctx.root, "@snapshots", "frozen"])
      mem = Path.join([ctx.root, "@snapshots", "frozen.mem"])
      File.mkdir_p!(snap)
      File.mkdir_p!(mem)
      File.write!(Path.join(mem, "state.json"), "{}")
      File.write!(Path.join([ctx.root, "@snapshots", "frozen.json"]), ~s({"name":"frozen"}))

      assert :ok = Mjolnir.BTRFS.delete_snapshot("frozen")
      refute File.exists?(Path.join([ctx.root, "@snapshots", "frozen.json"]))
      refute File.exists?(mem)
    end
  end

  describe "freeze/3 does not pretend the source survives" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "memsnap-freeze-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "@snapshots"))
      prev = Application.get_env(:mjolnir, :btrfs_root)
      Application.put_env(:mjolnir, :btrfs_root, tmp)

      on_exit(fn ->
        File.rm_rf!(tmp)
        if prev, do: Application.put_env(:mjolnir, :btrfs_root, prev)
      end)

      {:ok, root: tmp}
    end

    test "refuses a name whose memory dir already exists, without pausing", ctx do
      # Pausing first would stop a live VM for a freeze that was never going to
      # happen — and since vm.snapshot is terminal, a needless pause on the way
      # to an error is a needless outage.
      File.mkdir_p!(Path.join([ctx.root, "@snapshots", "taken.mem"]))
      test_pid = self()

      assert {:error, {:snapshot_exists, "taken"}} =
               MemorySnapshot.freeze(
                 %{id: "vm-1", socket_path: "/nope.sock"},
                 "taken",
                 pause_fun: fn _ ->
                   send(test_pid, :paused)
                   :ok
                 end
               )

      refute_receive :paused, 50
    end

    test "a failed pause reports pause_failed and captures nothing", ctx do
      assert {:error, {:pause_failed, :boom}} =
               MemorySnapshot.freeze(
                 %{id: "vm-1", socket_path: "/nope.sock"},
                 "fresh",
                 pause_fun: fn _ -> {:error, :boom} end
               )

      refute File.exists?(Path.join([ctx.root, "@snapshots", "fresh.mem"]))
    end

    test "a managed VM without vsock and without quiesce_fun is refused, without pausing",
         ctx do
      # The structural guarantee: a secrets VM cannot take a naive memory
      # snapshot. Missing the wipe is a refusal, not a skip.
      _ = ctx
      test_pid = self()

      assert {:error, {:secrets_quiesce_required, :managed}} =
               MemorySnapshot.freeze(
                 %{id: "vm-1", socket_path: "/nope.sock", secrets_mode: :managed},
                 "fresh",
                 pause_fun: fn _ ->
                   send(test_pid, :paused)
                   :ok
                 end
               )

      refute_receive :paused, 50
    end

    test "the same refusal holds for :persistent" do
      assert {:error, {:secrets_quiesce_required, :persistent}} =
               MemorySnapshot.freeze(
                 %{id: "vm-1", socket_path: "/nope.sock", secrets_mode: :persistent},
                 "fresh",
                 pause_fun: fn _ -> :ok end
               )
    end

    test "failed quiesce never pauses" do
      test_pid = self()

      assert {:error, {:secrets_quiesce_failed, :nope}} =
               MemorySnapshot.freeze(
                 %{id: "vm-1", socket_path: "/nope.sock", secrets_mode: :managed},
                 "fresh",
                 quiesce_fun: fn _vm, :managed -> {:error, :nope} end,
                 pause_fun: fn _ ->
                   send(test_pid, :paused)
                   :ok
                 end
               )

      refute_receive :paused, 50
    end

    test "quiesce runs before pause for a managed VM" do
      test_pid = self()

      # Capture will fail (no BTRFS); we only care about the order.
      _ =
        MemorySnapshot.freeze(
          %{id: "vm-1", socket_path: "/nope.sock", secrets_mode: :managed},
          "fresh",
          quiesce_fun: fn vm, :managed ->
            send(test_pid, {:quiesced, vm.id})
            {:ok, %{suspended: true}}
          end,
          pause_fun: fn _ ->
            send(test_pid, :paused)
            {:error, :stop_here}
          end
        )

      assert_received {:quiesced, "vm-1"}
      assert_received :paused
    end

    test "secrets_mode can be passed as an option rather than on the vm map" do
      assert {:error, {:secrets_quiesce_required, :managed}} =
               MemorySnapshot.freeze(
                 %{id: "vm-1", socket_path: "/nope.sock"},
                 "fresh",
                 secrets_mode: :managed,
                 pause_fun: fn _ -> :ok end
               )
    end

    test "a :none VM still skips quiesce (unit tests, no guest)" do
      # Existing callers pass no secrets_mode. They must keep working.
      assert {:error, {:pause_failed, :boom}} =
               MemorySnapshot.freeze(
                 %{id: "vm-1", socket_path: "/nope.sock"},
                 "fresh",
                 pause_fun: fn _ -> {:error, :boom} end
               )
    end

    test "freeze/3 takes no :resume_fun — there is no resume to override" do
      # Guards the correction in this module's docs. vm.snapshot is TERMINAL for
      # a virtio-fs VM: measured on the host, a 1/sec tick stopped dead after
      # snapshot+resume while CH still reported Running and a second resume
      # returned 500. The old code called resume in an `after` block and logged
      # success, which handed back a VM that health checks would call alive
      # while nothing inside it executed. If a :resume_fun option ever comes
      # back, that mistake has come back with it.
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(MemorySnapshot)

      freeze_doc =
        Enum.find_value(docs, fn
          {{:function, :freeze, 3}, _, _, %{"en" => doc}, _} -> doc
          _ -> nil
        end)

      refute freeze_doc =~ ":resume_fun"
      assert freeze_doc =~ "ONE-WAY PARK"
    end
  end

  describe "prepare_thaw/2 refusals" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "memsnap-thaw-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "@snapshots"))
      prev = Application.get_env(:mjolnir, :btrfs_root)
      Application.put_env(:mjolnir, :btrfs_root, tmp)

      on_exit(fn ->
        File.rm_rf!(tmp)
        if prev, do: Application.put_env(:mjolnir, :btrfs_root, prev)
      end)

      {:ok, root: tmp}
    end

    test "refuses when there is no memory image", ctx do
      File.mkdir_p!(Path.join([ctx.root, "@snapshots", "fs-only"]))

      assert {:error, {:memory_snapshot_not_found, "fs-only"}} =
               MemorySnapshot.prepare_thaw("fs-only", "new-vm-id")
    end

    test "refuses a snapshot whose sidecar records no pin", ctx do
      # Pre-pinning snapshots cannot prove their filesystem is unchanged. For a
      # cold boot that is merely stale; for a memory restore it is potential
      # silent corruption, so an unprovable pin is treated as a failed pin.
      mem = Path.join([ctx.root, "@snapshots", "legacy.mem"])
      File.mkdir_p!(mem)
      File.write!(Path.join(mem, "state.json"), "{}")
      File.mkdir_p!(Path.join([ctx.root, "@snapshots", "legacy"]))

      File.write!(
        Path.join([ctx.root, "@snapshots", "legacy.json"]),
        Jason.encode!(%{name: "legacy", created_at: "2026-01-01T00:00:00Z"})
      )

      assert {:error, {:snapshot_pin_unknown, "legacy"}} =
               MemorySnapshot.prepare_thaw("legacy", "new-vm-id")
    end
  end
end
