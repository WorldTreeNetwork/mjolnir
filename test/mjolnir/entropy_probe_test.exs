defmodule Mjolnir.Entropy.ProbeTest do
  @moduledoc """
  mjolnir-3y6.5 — the concurrent two-thaw key probe, without KVM.

  Host-side steps are injected. What this pins is the control flow the
  acceptance criterion needs: thaw twice with remap, reseed both, sample
  both, report whether the keys diverged, and tear both down even when a
  later step fails.
  """
  use ExUnit.Case, async: true

  alias Mjolnir.Entropy.Probe

  defp thawed(id) do
    %{
      vm_id: id,
      vsock_socket: "/tmp/#{id}_vsock",
      fs_socket: "/tmp/#{id}_virtiofs.sock",
      extra_fs_sockets: [],
      staged: true
    }
  end

  describe "run/2" do
    test "two reseeds then two samples; diverged when the keys differ" do
      test_pid = self()

      thaw = fn name, id, opts ->
        assert name == "frozen"
        assert opts[:remap] == true
        send(test_pid, {:thaw, id})
        {:ok, thawed(id)}
      end

      connect = fn thawed, _opts ->
        send(test_pid, {:connect, thawed.vm_id})
        {:ok, {:conn, thawed.vm_id}}
      end

      reseed_fun = fn conn ->
        send(test_pid, {:reseed, conn})
        :ok
      end

      sample = fn conn, bytes ->
        assert bytes == 16
        send(test_pid, {:sample, conn})

        case conn do
          {:conn, "vm-a"} -> {:ok, "aa"}
          {:conn, "vm-b"} -> {:ok, "bb"}
        end
      end

      torn = :ets.new(:torn, [:public])

      teardown = fn boot ->
        :ets.insert(torn, {boot.vm_id, true})
        :ok
      end

      assert {:ok, result} =
               Probe.run("frozen",
                 id_a: "vm-a",
                 id_b: "vm-b",
                 thaw: thaw,
                 connect: connect,
                 reseed_fun: reseed_fun,
                 sample: sample,
                 teardown: teardown
               )

      assert result.diverged
      assert result.reseeded
      assert result.key_a == "aa"
      assert result.key_b == "bb"
      assert result.vm_a == "vm-a"
      assert result.vm_b == "vm-b"

      assert_received {:thaw, "vm-a"}
      assert_received {:thaw, "vm-b"}
      assert_received {:connect, "vm-a"}
      assert_received {:connect, "vm-b"}
      assert_received {:reseed, {:conn, "vm-a"}}
      assert_received {:reseed, {:conn, "vm-b"}}
      assert_received {:sample, {:conn, "vm-a"}}
      assert_received {:sample, {:conn, "vm-b"}}
      assert :ets.lookup(torn, "vm-a") == [{"vm-a", true}]
      assert :ets.lookup(torn, "vm-b") == [{"vm-b", true}]
    end

    test "control (reseed: false) still samples both guests" do
      test_pid = self()

      thaw = fn _n, id, opts ->
        assert opts[:remap] == true
        {:ok, thawed(id)}
      end

      connect = fn thawed, _ -> {:ok, {:conn, thawed.vm_id}} end
      reseed_fun = fn _conn -> send(test_pid, :reseeded) && :ok end

      sample = fn _conn, _bytes -> {:ok, "same"} end
      teardown = fn _ -> :ok end

      assert {:ok, result} =
               Probe.run("frozen",
                 id_a: "vm-a",
                 id_b: "vm-b",
                 reseed: false,
                 thaw: thaw,
                 connect: connect,
                 reseed_fun: reseed_fun,
                 sample: sample,
                 teardown: teardown
               )

      refute result.diverged
      refute result.reseeded
      refute_received :reseeded
    end

    test "tears down the first thaw if the second thaw fails" do
      torn = :ets.new(:torn, [:public])

      thaw = fn _n, id, _opts ->
        if id == "vm-b" do
          {:error, :virtiofsd_socket_in_use}
        else
          {:ok, thawed(id)}
        end
      end

      connect = fn thawed, _ -> {:ok, {:conn, thawed.vm_id}} end
      teardown = fn boot -> :ets.insert(torn, {boot.vm_id, true}) end

      assert {:error, {:thaw_failed, "vm-b", :virtiofsd_socket_in_use}} =
               Probe.run("frozen",
                 id_a: "vm-a",
                 id_b: "vm-b",
                 thaw: thaw,
                 connect: connect,
                 teardown: teardown
               )

      assert :ets.lookup(torn, "vm-a") == [{"vm-a", true}]
      assert :ets.lookup(torn, "vm-b") == []
    end

    test "tears down both thaws if reseed fails" do
      torn = :ets.new(:torn, [:public])

      thaw = fn _n, id, _opts -> {:ok, thawed(id)} end
      connect = fn thawed, _ -> {:ok, {:conn, thawed.vm_id}} end

      reseed_fun = fn
        {:conn, "vm-b"} -> {:error, :credited_nothing}
        _ -> :ok
      end

      teardown = fn boot -> :ets.insert(torn, {boot.vm_id, true}) end

      assert {:error, :credited_nothing} =
               Probe.run("frozen",
                 id_a: "vm-a",
                 id_b: "vm-b",
                 thaw: thaw,
                 connect: connect,
                 reseed_fun: reseed_fun,
                 teardown: teardown
               )

      assert :ets.lookup(torn, "vm-a") == [{"vm-a", true}]
      assert :ets.lookup(torn, "vm-b") == [{"vm-b", true}]
    end
  end
end
