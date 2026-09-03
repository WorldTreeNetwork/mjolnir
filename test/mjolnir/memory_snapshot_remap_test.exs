defmodule Mjolnir.MemorySnapshotRemapTest do
  @moduledoc """
  mjolnir-3y6.5 — per-thaw identity remap.

  Two restores from one memory snapshot used to collide on the virtiofsd
  socket and vsock CID baked into config.json. The rewrite is the slice
  that makes the concurrent key probe runnable. Full fork (guest IP,
  machine-id, net_fds) is mjolnir-8m3 and is not covered here.
  """
  use ExUnit.Case, async: true

  alias Mjolnir.MemorySnapshot

  @source_config %{
    "cpus" => %{"boot_vcpus" => 1, "max_vcpus" => 1},
    "memory" => %{"size" => 536_870_912, "shared" => true},
    "payload" => %{
      "kernel" => "/var/lib/mjolnir/vmlinux-ch",
      "cmdline" => "console=ttyS0 reboot=k panic=1 rw"
    },
    "rng" => %{"src" => "/dev/urandom"},
    "fs" => [
      %{
        "id" => "_fs0",
        "tag" => "myfs",
        "socket" => "/tmp/cfgprobe/fs.sock"
      },
      %{
        "id" => "_fs1",
        "tag" => "repo",
        "socket" => "/tmp/cfgprobe/repo.sock"
      }
    ],
    "vsock" => %{
      "id" => "_vsock1",
      "cid" => 78_123_499,
      "socket" => "/tmp/cfgprobe/vsock"
    },
    "net" => [
      %{
        "id" => "_net0",
        "tap" => "mj-abc12345",
        "mac" => "02:00:00:aa:bb:cc"
      }
    ]
  }

  @id_a "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @id_b "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

  describe "remap_config/3" do
    test "two identities get distinct sockets, CIDs, and TAP names" do
      socket_dir = "/tmp/mj-remap"
      a = MemorySnapshot.remap_config(@source_config, @id_a, socket_dir)
      b = MemorySnapshot.remap_config(@source_config, @id_b, socket_dir)

      assert get_in(a, ["fs", Access.at(0), "socket"]) !=
               get_in(b, ["fs", Access.at(0), "socket"])

      assert get_in(a, ["vsock", "socket"]) != get_in(b, ["vsock", "socket"])
      assert get_in(a, ["vsock", "cid"]) != get_in(b, ["vsock", "cid"])
      assert get_in(a, ["net", Access.at(0), "tap"]) != get_in(b, ["net", Access.at(0), "tap"])
    end

    test "keeps the original guest MAC" do
      remapped = MemorySnapshot.remap_config(@source_config, @id_a, "/tmp/mj-remap")
      assert get_in(remapped, ["net", Access.at(0), "mac"]) == "02:00:00:aa:bb:cc"
    end

    test "rewrites sockets onto the new identity's conventional paths" do
      socket_dir = "/tmp/mj-remap"
      remapped = MemorySnapshot.remap_config(@source_config, @id_a, socket_dir)

      assert get_in(remapped, ["fs", Access.at(0), "socket"]) ==
               Mjolnir.VirtioFS.socket_path(socket_dir, @id_a)

      assert get_in(remapped, ["fs", Access.at(1), "socket"]) ==
               Mjolnir.VirtioFS.socket_path(socket_dir, @id_a, "repo")

      assert get_in(remapped, ["vsock", "socket"]) ==
               Mjolnir.Hypervisor.CloudHypervisor.vsock_path(socket_dir, @id_a)

      assert get_in(remapped, ["vsock", "cid"]) == Mjolnir.Vsock.cid(@id_a)
      assert get_in(remapped, ["net", Access.at(0), "tap"]) == Mjolnir.Network.tap_name(@id_a)
    end

    test "does not invent a net device when the snapshot had none" do
      config = Map.delete(@source_config, "net")
      remapped = MemorySnapshot.remap_config(config, @id_a, "/tmp/mj-remap")
      refute Map.has_key?(remapped, "net")
    end
  end

  describe "stage_fork/3" do
    setup do
      src = Path.join(System.tmp_dir!(), "memsrc-#{System.unique_integer([:positive])}")
      dest_root = Path.join(System.tmp_dir!(), "memdst-#{System.unique_integer([:positive])}")
      File.mkdir_p!(src)
      File.write!(Path.join(src, "config.json"), Jason.encode!(@source_config))
      File.write!(Path.join(src, "state.json"), ~s({"dummy": true}))
      File.write!(Path.join(src, "memory-ranges"), "not-really-ram")

      on_exit(fn ->
        File.rm_rf(src)
        File.rm_rf(dest_root)
      end)

      {:ok, src: src, dest_root: dest_root}
    end

    test "writes a rewritten config and copies the RAM image", ctx do
      dest = Path.join(ctx.dest_root, @id_a)

      assert {:ok, %{memory_dir: ^dest, config: config}} =
               MemorySnapshot.stage_fork("frozen", @id_a,
                 source: ctx.src,
                 dest: dest,
                 socket_dir: "/tmp/mj-remap"
               )

      assert File.exists?(Path.join(dest, "memory-ranges"))
      assert File.exists?(Path.join(dest, "state.json"))
      assert get_in(config, ["vsock", "cid"]) == Mjolnir.Vsock.cid(@id_a)
      assert get_in(config, ["net", Access.at(0), "mac"]) == "02:00:00:aa:bb:cc"
    end

    test "refuses to clobber an existing staged fork", ctx do
      dest = Path.join(ctx.dest_root, @id_a)

      assert {:ok, _} =
               MemorySnapshot.stage_fork("frozen", @id_a,
                 source: ctx.src,
                 dest: dest,
                 socket_dir: "/tmp/mj-remap"
               )

      assert {:error, {:fork_exists, ^dest}} =
               MemorySnapshot.stage_fork("frozen", @id_a,
                 source: ctx.src,
                 dest: dest,
                 socket_dir: "/tmp/mj-remap"
               )
    end
  end

  describe "preflight after remap" do
    test "two remapped thaws do not collide on the original socket" do
      socket_dir = "/tmp/mj-remap"
      a = MemorySnapshot.remap_config(@source_config, @id_a, socket_dir)
      b = MemorySnapshot.remap_config(@source_config, @id_b, socket_dir)

      assert {:ok, req_a} = MemorySnapshot.required_backends(a)
      assert {:ok, req_b} = MemorySnapshot.required_backends(b)

      assert req_a.fs_socket != req_b.fs_socket
      assert req_a.vsock_cid != req_b.vsock_cid
      assert req_a.tap != req_b.tap
      assert req_a.mac == req_b.mac

      assert :ok = MemorySnapshot.preflight(req_a)
      assert :ok = MemorySnapshot.preflight(req_b)
    end
  end

  describe "prepare_backends/3 with a remapped identity" do
    setup do
      dir = Path.join(System.tmp_dir!(), "remap-be-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok,
       dir: dir,
       prep: %{
         rootfs_path: Path.join(dir, "clone"),
         memory_dir: Path.join(dir, "mem"),
         metadata: %{name: "frozen", source_vm_id: "vm-frozen", generation: 42},
         tap_vm_id: @id_a,
         verify_guest_mac: false
       }}
    end

    test "creates the TAP for the NEW identity, not the frozen one", ctx do
      sock = Path.join(ctx.dir, "fs.sock")
      test_pid = self()
      expected_tap = Mjolnir.Network.tap_name(@id_a)

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
                   mac: "02:00:00:aa:bb:cc"
                 },
                 virtiofs_start: virtiofs_start,
                 tap_create: tap_create
               )

      assert_receive {:tap_for, @id_a}
      refute_received {:tap_for, "vm-frozen"}
      assert net.tap_name == expected_tap
    end
  end
end
