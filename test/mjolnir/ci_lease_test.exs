defmodule Mjolnir.CILeaseTest.FakeVM do
  @moduledoc """
  Stand-in for a real Mjolnir.VM GenServer, registered under the same
  Registry. `Mjolnir.VM.stop/1` only ever interacts with a VM through
  `Registry.lookup/2` + `GenServer.stop/3` — it has no other way to reach a
  hypervisor or BTRFS. So if this fake gets a clean `GenServer.stop(pid,
  :normal, _)`, whatever called it (here, `CILease.sweep/1`) went through the
  real `VM.stop/1` contract rather than some direct/hard-delete shortcut.
  """
  use GenServer

  def start_link(vm_id) do
    GenServer.start_link(__MODULE__, vm_id)
  end

  @impl true
  def init(vm_id) do
    {:ok, _} = Registry.register(Mjolnir.VMRegistry, vm_id, nil)
    {:ok, vm_id}
  end
end

defmodule Mjolnir.CILeaseTest do
  use ExUnit.Case, async: false

  alias Mjolnir.CILease
  alias Mjolnir.CILeaseTest.FakeVM
  alias Mjolnir.StateStore
  alias Mjolnir.StateStore.Record

  # StateStore is a single app-wide GenServer; reuse it with a per-test
  # state_dir (same pattern as test/state_store_test.exs) so these tests
  # never race the real durability directory.
  setup do
    tmp =
      Path.join([
        System.tmp_dir!(),
        "mjolnir-ci-lease-test",
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

    :ok
  end

  defp put_record(uuid, opts) do
    record =
      Record.new(uuid, Keyword.get(opts, :intent, :running),
        metadata: Keyword.get(opts, :metadata, %{}),
        runtime: Keyword.get(opts, :runtime, %{})
      )

    :ok = StateStore.put(record)
    {:ok, stored} = StateStore.get(uuid)
    stored
  end

  describe "eligible_for_reclaim?/2 — the safety-critical predicate" do
    test "1. an expired CI-tagged VM IS selected for reclamation" do
      now = 1_000_000
      expired_at = now - 60

      record =
        put_record("vm-1",
          metadata: %{"purpose" => "ci"},
          runtime: %{"lease_expires_at" => expired_at}
        )

      assert CILease.eligible_for_reclaim?(record, now)
    end

    test "2. a non-CI VM with a long-expired lease is NOT selected" do
      # Written as if someone will later "optimise" this guard away: a VM
      # with ANY purpose other than exactly "ci" — including one that merely
      # happens to also carry an expired lease_expires_at — must never be
      # reaped. Absence of the "ci" tag is the whole gate.
      now = 1_000_000
      long_expired = now - 10 * 24 * 60 * 60

      record =
        put_record("vm-2",
          metadata: %{"purpose" => "interactive"},
          runtime: %{"lease_expires_at" => long_expired}
        )

      refute CILease.eligible_for_reclaim?(record, now)

      # And the no-metadata-at-all sibling of this case:
      record2 = put_record("vm-2b", runtime: %{"lease_expires_at" => long_expired})
      refute CILease.eligible_for_reclaim?(record2, now)
    end

    test "3. a VM with NO metadata is NOT selected" do
      now = 1_000_000
      record = put_record("vm-3", runtime: %{"lease_expires_at" => now - 60})

      assert record.metadata == %{}
      refute CILease.eligible_for_reclaim?(record, now)
    end

    test "4. a CI VM with no lease_expires_at is NOT selected" do
      now = 1_000_000
      record = put_record("vm-4", metadata: %{"purpose" => "ci"})

      assert CILease.lease_expires_at(record) == nil
      refute CILease.eligible_for_reclaim?(record, now)
    end

    test "5. a CI VM whose lease is still valid is NOT selected" do
      now = 1_000_000
      not_yet_expired = now + 60

      record =
        put_record("vm-5",
          metadata: %{"purpose" => "ci"},
          runtime: %{"lease_expires_at" => not_yet_expired}
        )

      refute CILease.eligible_for_reclaim?(record, now)
    end
  end

  describe "renew/2" do
    test "renews the lease on a CI-owned VM using the configured TTL" do
      prev_ttl = Application.get_env(:mjolnir, :ci_lease_seconds)
      # Short configured TTL rather than sleeping to observe expiry.
      Application.put_env(:mjolnir, :ci_lease_seconds, 5)

      on_exit(fn ->
        if prev_ttl, do: Application.put_env(:mjolnir, :ci_lease_seconds, prev_ttl)
      end)

      put_record("vm-renew", metadata: %{"purpose" => "ci"})

      now = 1_000_000
      assert :ok = CILease.renew("vm-renew", now)

      {:ok, stored} = StateStore.get("vm-renew")
      assert CILease.lease_expires_at(stored) == now + 5
      # Not yet expired at now, but expired 6s later.
      refute CILease.eligible_for_reclaim?(stored, now)
      assert CILease.eligible_for_reclaim?(stored, now + 6)
    end

    test "is a no-op for a non-CI VM (never manufactures a lease)" do
      put_record("vm-not-ci", metadata: %{"purpose" => "interactive"})

      assert :ok = CILease.renew("vm-not-ci", 1_000_000)

      {:ok, stored} = StateStore.get("vm-not-ci")
      assert CILease.lease_expires_at(stored) == nil
    end

    test "is a no-op for a VM with no record" do
      assert :ok = CILease.renew("vm-does-not-exist", 1_000_000)
    end
  end

  describe "sweep/1 — routes reclamation through Mjolnir.VM.stop, never a hard delete" do
    test "6. an eligible CI VM's live GenServer is stopped through the existing teardown path" do
      vm_id = "vm-sweep-#{System.unique_integer([:positive])}"
      now = 1_000_000

      put_record(vm_id,
        metadata: %{"purpose" => "ci", "repo" => "identikey/mjolnir"},
        runtime: %{"lease_expires_at" => now - 3600}
      )

      {:ok, fake_pid} = FakeVM.start_link(vm_id)
      ref = Process.monitor(fake_pid)

      assert CILease.sweep(now) == [vm_id]

      assert_receive {:DOWN, ^ref, :process, ^fake_pid, :normal}, 1_000
    end

    test "does not attempt to reclaim a CI VM whose lease is still valid" do
      vm_id = "vm-sweep-valid-#{System.unique_integer([:positive])}"
      now = 1_000_000

      put_record(vm_id,
        metadata: %{"purpose" => "ci"},
        runtime: %{"lease_expires_at" => now + 3600}
      )

      assert CILease.sweep(now) == []
    end

    test "does not attempt to reclaim a non-CI VM even with a long-expired lease" do
      vm_id = "vm-sweep-noncil-#{System.unique_integer([:positive])}"
      now = 1_000_000

      put_record(vm_id,
        metadata: %{"purpose" => "interactive"},
        runtime: %{"lease_expires_at" => now - 100_000}
      )

      assert CILease.sweep(now) == []
    end
  end

  describe "stamp_runtime/3 — the lease must survive a restart" do
    # VM.build_running_record/1 rebuilds `runtime` from scratch on every boot
    # AND resume, so a lease written by renew/2 does not survive a restart.
    # Since eligibility fails closed on a missing lease, an unstamped CI VM
    # that outlives a Mjolnir restart would be permanently unreclaimable —
    # exactly the accumulation-across-restarts described in mjolnir-24r. These
    # pin the stamping that closes that hole.
    test "stamps a lease onto a CI VM's freshly built runtime map" do
      now = 1_000_000

      runtime =
        CILease.stamp_runtime(%{"ch_api_socket" => "/tmp/x.sock"}, %{"purpose" => "ci"}, now)

      assert runtime["lease_expires_at"] == now + CILease.lease_seconds()
      # Must not clobber what build_running_record put there.
      assert runtime["ch_api_socket"] == "/tmp/x.sock"
    end

    test "a stamped CI record is reclaimable once that lease expires" do
      now = 1_000_000
      runtime = CILease.stamp_runtime(%{}, %{"purpose" => "ci"}, now)

      record =
        Record.new("vm-stamped-#{System.unique_integer([:positive])}", :running,
          metadata: %{"purpose" => "ci"},
          runtime: runtime
        )

      refute CILease.eligible_for_reclaim?(record, now)
      refute CILease.eligible_for_reclaim?(record, now + CILease.lease_seconds())
      assert CILease.eligible_for_reclaim?(record, now + CILease.lease_seconds() + 1)
    end

    test "never stamps a non-CI VM — a user VM must never become reclaimable" do
      now = 1_000_000

      for metadata <- [%{"purpose" => "interactive"}, %{}, nil, %{"purpose" => "CI"}] do
        runtime = CILease.stamp_runtime(%{"vsock_uds" => "/tmp/v"}, metadata, now)

        refute Map.has_key?(runtime, "lease_expires_at"),
               "stamped a lease for metadata #{inspect(metadata)} — that VM would become " <>
                 "eligible for automatic destruction"

        assert runtime["vsock_uds"] == "/tmp/v"
      end
    end
  end
end
