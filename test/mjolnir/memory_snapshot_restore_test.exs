defmodule Mjolnir.MemorySnapshotRestoreTest do
  @moduledoc """
  mjolnir-3y6.4 — hazards 2 and 5, the restore bring-up ordering.

  Cloud Hypervisor *reconnects* to vhost-user backends; it does not respawn
  them, and it cannot restore into a VM that has been created or booted. So
  everything the snapshot names must already be listening before the VMM
  starts. When it is not, CH does not report a missing daemon — `vm.restore`
  hangs forever or the guest wedges on first I/O, which reads as a hypervisor
  bug. Every prerequisite therefore has to fail here, with its own error.

  The effects (virtiofsd, TAP) are injected, so these run on macOS. What they
  pin is the decision-making: what is required, what is refused, and in which
  order things are brought up.
  """
  use ExUnit.Case, async: true

  alias Mjolnir.MemorySnapshot

  # Verbatim from a real Cloud Hypervisor v53 snapshot taken on 45.76.77.97.
  # Kept whole rather than reduced: the point is that CH records ABSOLUTE
  # socket paths and a CID, which is the constraint the entire orchestration
  # is built around, and a hand-trimmed sample invites forgetting that.
  @real_config %{
    "cpus" => %{"boot_vcpus" => 1, "max_vcpus" => 1},
    "memory" => %{"size" => 536_870_912, "shared" => true},
    "payload" => %{
      "kernel" => "/var/lib/mjolnir/vmlinux-ch",
      "cmdline" => "console=ttyS0 reboot=k panic=1 rw",
      "initramfs" => "/var/lib/mjolnir/boot/initramfs.img"
    },
    "rng" => %{"pci_segment" => 0, "src" => "/dev/urandom"},
    "fs" => [
      %{
        "id" => "_fs0",
        "pci_segment" => 0,
        "tag" => "myfs",
        "socket" => "/tmp/cfgprobe/fs.sock",
        "num_queues" => 1,
        "queue_size" => 1024
      }
    ],
    "vsock" => %{
      "id" => "_vsock1",
      "pci_segment" => 0,
      "cid" => 78_123_499,
      "socket" => "/tmp/cfgprobe/vsock"
    }
  }

  describe "required_backends/1" do
    test "extracts the socket paths CH will reconnect to" do
      assert {:ok, req} = MemorySnapshot.required_backends(@real_config)

      # These are absolute and belong to the FROZEN vm. A thaw cannot put its
      # backends where a new VM would normally go.
      assert req.fs_socket == "/tmp/cfgprobe/fs.sock"
      assert req.vsock_socket == "/tmp/cfgprobe/vsock"
      assert req.vsock_cid == 78_123_499
      assert req.extra_fs_sockets == []
    end

    test "a VM snapshotted without networking has no tap to recreate" do
      assert {:ok, %{tap: nil, mac: nil}} = MemorySnapshot.required_backends(@real_config)
    end

    test "picks up tap and mac when the snapshot had a network" do
      config =
        Map.put(@real_config, "net", [
          %{"tap" => "mj-abc123", "mac" => "02:00:00:aa:bb:cc", "id" => "_net0"}
        ])

      assert {:ok, %{tap: "mj-abc123", mac: "02:00:00:aa:bb:cc"}} =
               MemorySnapshot.required_backends(config)
    end

    test "carries extra virtio-fs mounts, which also need daemons" do
      config =
        Map.put(@real_config, "fs", [
          %{"tag" => "myfs", "socket" => "/s/fs.sock"},
          %{"tag" => "repo", "socket" => "/s/repo.sock"}
        ])

      assert {:ok, %{fs_socket: "/s/fs.sock", extra_fs_sockets: ["/s/repo.sock"]}} =
               MemorySnapshot.required_backends(config)
    end

    test "refuses a config with no fs device instead of guessing" do
      # A Mjolnir VM's rootfs is always virtio-fs. Defaulting a socket path
      # here would produce a restore that hangs on first I/O rather than an
      # error anyone can read.
      assert {:error, {:snapshot_config_no_fs, _}} =
               MemorySnapshot.required_backends(Map.delete(@real_config, "fs"))
    end
  end

  describe "read_snapshot_config/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "snapcfg-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "reads and decodes a real config.json", ctx do
      File.write!(Path.join(ctx.dir, "config.json"), Jason.encode!(@real_config))
      assert {:ok, config} = MemorySnapshot.read_snapshot_config(ctx.dir)
      assert get_in(config, ["fs", Access.at(0), "socket"]) == "/tmp/cfgprobe/fs.sock"
    end

    test "names the missing file rather than failing opaquely", ctx do
      assert {:error, {:snapshot_config_missing, path}} =
               MemorySnapshot.read_snapshot_config(ctx.dir)

      assert String.ends_with?(path, "config.json")
    end

    test "reports a corrupt config distinctly from a missing one", ctx do
      # A truncated snapshot (out of disk mid-freeze) must not look like
      # "no snapshot here".
      File.write!(Path.join(ctx.dir, "config.json"), "{\"fs\": [trunc")

      assert {:error, {:snapshot_config_unreadable, _, _}} =
               MemorySnapshot.read_snapshot_config(ctx.dir)
    end
  end

  describe "socket_live?/1 and preflight/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "sockprobe-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "a path that does not exist is not live", ctx do
      refute MemorySnapshot.socket_live?(Path.join(ctx.dir, "nope.sock"))
    end

    test "a stale socket FILE with no listener is not live", ctx do
      # The normal aftermath of a killed VMM. Treating the inode's existence as
      # a collision would refuse every thaw after an unclean shutdown.
      stale = Path.join(ctx.dir, "stale.sock")
      File.write!(stale, "")
      refute MemorySnapshot.socket_live?(stale)
      assert :ok = MemorySnapshot.preflight(%{fs_socket: stale, extra_fs_sockets: []})
    end

    test "a socket with a real listener is live and refuses the thaw", ctx do
      # Two thaws of one snapshot want the SAME socket path, because it is
      # baked into config.json. Without this the second silently attaches to
      # the first VM's virtiofsd — one daemon, two guests, each believing it
      # owns the filesystem.
      path = Path.join(ctx.dir, "live.sock")
      {:ok, listener} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}])
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert MemorySnapshot.socket_live?(path)

      assert {:error, {:virtiofsd_socket_in_use, ^path}} =
               MemorySnapshot.preflight(%{fs_socket: path, extra_fs_sockets: []})
    end

    test "an extra mount's socket collision is caught too", ctx do
      path = Path.join(ctx.dir, "extra.sock")
      {:ok, listener} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}])
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:error, {:virtiofsd_socket_in_use, ^path}} =
               MemorySnapshot.preflight(%{
                 fs_socket: Path.join(ctx.dir, "free.sock"),
                 extra_fs_sockets: [path]
               })
    end
  end

  describe "prepare_backends/3 — the ordering and its loud failures" do
    setup do
      dir = Path.join(System.tmp_dir!(), "backends-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok,
       dir: dir,
       prep: %{
         rootfs_path: Path.join(dir, "clone"),
         memory_dir: Path.join(dir, "mem"),
         metadata: %{name: "frozen", source_vm_id: "vm-frozen", generation: 42}
       }}
    end

    test "starts virtiofsd against the CLONE on the snapshot's socket path", ctx do
      sock = Path.join(ctx.dir, "fs.sock")
      test_pid = self()

      virtiofs_start = fn shared_dir, socket_path ->
        send(test_pid, {:virtiofsd, shared_dir, socket_path})
        {:ok, listener} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, socket_path}])
        on_exit(fn -> :gen_tcp.close(listener) end)
        {:ok, listener}
      end

      assert {:ok, _} =
               MemorySnapshot.prepare_backends(
                 ctx.prep,
                 %{fs_socket: sock, extra_fs_sockets: [], tap: nil, mac: nil},
                 virtiofs_start: virtiofs_start
               )

      # Decoupling these two is the trick that lets a thaw serve a fresh,
      # pinned filesystem without CH noticing: NEW shared dir, OLD socket path.
      assert_receive {:virtiofsd, shared_dir, socket_path}
      assert shared_dir == ctx.prep.rootfs_path
      assert socket_path == sock
    end

    test "fails loudly when virtiofsd starts but never listens", ctx do
      # The hazard-2 failure. Left to CH this is an infinite hang, not an error.
      slow = fn _shared, _sock -> {:ok, :fake_port} end

      assert {:error, {:backend_socket_not_listening, path, _timeout}} =
               MemorySnapshot.prepare_backends(
                 ctx.prep,
                 %{
                   fs_socket: Path.join(ctx.dir, "never.sock"),
                   extra_fs_sockets: [],
                   tap: nil,
                   mac: nil
                 },
                 virtiofs_start: slow,
                 socket_timeout_ms: 200
               )

      assert String.ends_with?(path, "never.sock")
    end

    test "propagates a virtiofsd that refuses to start at all", ctx do
      failing = fn _shared, _sock -> {:error, :enoent} end

      assert {:error, :enoent} =
               MemorySnapshot.prepare_backends(
                 ctx.prep,
                 %{fs_socket: Path.join(ctx.dir, "x.sock"), extra_fs_sockets: [], tap: nil},
                 virtiofs_start: failing
               )
    end

    test "recreates the TAP for the FROZEN vm id, not the new one", ctx do
      # The guest woke believing a specific MAC and IP, both hash-derived from
      # the original vm id. Creating them for the clone's new id yields a VM
      # that boots fine and has no working network.
      sock = Path.join(ctx.dir, "fs.sock")
      test_pid = self()
      expected_tap = Mjolnir.Network.tap_name("vm-frozen")

      virtiofs_start = fn _s, socket_path ->
        {:ok, l} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, socket_path}])
        on_exit(fn -> :gen_tcp.close(l) end)
        {:ok, l}
      end

      tap_create = fn vm_id ->
        send(test_pid, {:tap_for, vm_id})

        {:ok,
         %{
           tap_name: Mjolnir.Network.tap_name(vm_id),
           guest_ip: Mjolnir.Network.allocate_ip(vm_id),
           guest_mac: Mjolnir.Network.generate_mac(vm_id)
         }}
      end

      assert {:ok, %{net: net}} =
               MemorySnapshot.prepare_backends(
                 ctx.prep,
                 %{
                   fs_socket: sock,
                   extra_fs_sockets: [],
                   tap: expected_tap,
                   mac: Mjolnir.Network.generate_mac("vm-frozen")
                 },
                 virtiofs_start: virtiofs_start,
                 tap_create: tap_create
               )

      assert_receive {:tap_for, "vm-frozen"}
      assert net.tap_name == expected_tap
    end

    test "refuses when the recorded tap does not match the source vm id", ctx do
      # Means the snapshot metadata and the CH config disagree about which VM
      # this is. Bringing up a TAP anyway would give the guest a network that
      # silently does not work.
      virtiofs_start = fn _s, socket_path ->
        {:ok, l} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, socket_path}])
        on_exit(fn -> :gen_tcp.close(l) end)
        {:ok, l}
      end

      assert {:error, {:tap_name_mismatch, "mj-somethingelse", _derived}} =
               MemorySnapshot.prepare_backends(
                 ctx.prep,
                 %{
                   fs_socket: Path.join(ctx.dir, "fs.sock"),
                   extra_fs_sockets: [],
                   tap: "mj-somethingelse",
                   mac: nil
                 },
                 virtiofs_start: virtiofs_start
               )
    end

    test "surfaces a TAP that could not be created", ctx do
      virtiofs_start = fn _s, socket_path ->
        {:ok, l} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, socket_path}])
        on_exit(fn -> :gen_tcp.close(l) end)
        {:ok, l}
      end

      expected_tap = Mjolnir.Network.tap_name("vm-frozen")

      assert {:error, {:tap_setup_failed, ^expected_tap, :eperm}} =
               MemorySnapshot.prepare_backends(
                 ctx.prep,
                 %{
                   fs_socket: Path.join(ctx.dir, "fs.sock"),
                   extra_fs_sockets: [],
                   tap: expected_tap,
                   mac: nil
                 },
                 virtiofs_start: virtiofs_start,
                 tap_create: fn _ -> {:error, :eperm} end
               )
    end

    test "refuses a MAC that differs from what the guest holds in RAM", ctx do
      virtiofs_start = fn _s, socket_path ->
        {:ok, l} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, socket_path}])
        on_exit(fn -> :gen_tcp.close(l) end)
        {:ok, l}
      end

      expected_tap = Mjolnir.Network.tap_name("vm-frozen")

      assert {:error, {:tap_mac_mismatch, ^expected_tap, "02:00:00:de:ad:be", _}} =
               MemorySnapshot.prepare_backends(
                 ctx.prep,
                 %{
                   fs_socket: Path.join(ctx.dir, "fs.sock"),
                   extra_fs_sockets: [],
                   tap: expected_tap,
                   mac: "02:00:00:de:ad:be"
                 },
                 virtiofs_start: virtiofs_start,
                 tap_create: fn vm_id ->
                   {:ok,
                    %{
                      tap_name: Mjolnir.Network.tap_name(vm_id),
                      guest_ip: "10.0.0.5",
                      guest_mac: Mjolnir.Network.generate_mac(vm_id)
                    }}
                 end
               )
    end

    test "preflight runs BEFORE virtiofsd is started", ctx do
      # Ordering matters: starting a daemon and then discovering the collision
      # would leave a second virtiofsd attached to a socket the first owns.
      path = Path.join(ctx.dir, "busy.sock")
      {:ok, listener} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}])
      on_exit(fn -> :gen_tcp.close(listener) end)
      test_pid = self()

      assert {:error, {:virtiofsd_socket_in_use, ^path}} =
               MemorySnapshot.prepare_backends(
                 ctx.prep,
                 %{fs_socket: path, extra_fs_sockets: [], tap: nil},
                 virtiofs_start: fn _s, _p ->
                   send(test_pid, :started_anyway)
                   {:ok, :port}
                 end
               )

      refute_receive :started_anyway, 50
    end
  end
end
