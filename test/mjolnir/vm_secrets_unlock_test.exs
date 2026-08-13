defmodule Mjolnir.VMSecretsUnlockTest do
  # mjolnir-y32: the managed-secrets unlock runs off the VM process, so boot is
  # now a two-phase state machine — do_boot leaves the VM :booting with a
  # monitored worker outstanding, and one of three messages transitions it to
  # :running.
  #
  # Everything here guards the same failure: a VM stuck in :booting forever.
  # Nothing else in the system retries or reaps that state, and `spawn/1` is
  # parked on `await_boot` waiting for the reply, so a missed transition hangs
  # every managed spawn until its 90s timeout. The three terminations are the
  # worker reporting, the worker dying, and the watchdog firing.
  # NOT async: finish_boot/2 legitimately writes a :running StateStore record,
  # and the store is process-global in test. Left behind, those records surface
  # in GET /api/vms as stranded `recovering` VMs and fail unrelated API tests.
  use ExUnit.Case, async: false

  alias Mjolnir.VM

  # A VM mid-unlock: boot finished, worker outstanding, caller parked. vsock_conn
  # is nil so the (empty) message-queue drain is a no-op.
  defp booting_state(opts \\ []) do
    ref = Keyword.get(opts, :ref, make_ref())
    pid = Keyword.get(opts, :pid, self())
    id = "vm-unlock-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> Mjolnir.StateStore.delete(id) end)

    %VM{
      id: id,
      state: :booting,
      secrets_mode: :managed,
      config: %{base_image: "test", vcpu_count: 1, mem_size_mib: 512},
      restart_policy: :always,
      message_queue: [],
      secrets_unlock_ref: ref,
      secrets_unlock_pid: pid,
      secrets_unlock_timer: nil,
      boot_waiter: Keyword.get(opts, :boot_waiter)
    }
  end

  describe "the worker reports" do
    test ":ok transitions to :running with no recorded failure" do
      state = booting_state()

      assert {:noreply, running} =
               VM.handle_info({:secrets_unlock_result, state.secrets_unlock_pid, :ok}, state)

      assert running.state == :running
      assert running.secrets_unlock_failure == nil
    end

    test "an error still reaches :running, but records why" do
      # Log-and-continue is deliberate: a transient cryptsetup hiccup must not
      # wedge the boot. mjolnir-3v2 is the reason the outcome is recorded at
      # all — before it, a failed unlock left the VM reporting :running like
      # any healthy one while /run/mjolnir was never mounted.
      state = booting_state()

      assert {:noreply, running} =
               VM.handle_info(
                 {:secrets_unlock_result, state.secrets_unlock_pid, {:error, :timeout}},
                 state
               )

      assert running.state == :running
      assert %{reason: reason, at: %DateTime{}} = running.secrets_unlock_failure
      assert reason =~ "timeout"
    end

    test "the parked await_boot caller is answered" do
      # spawn/1 blocks here. Before the unlock moved off-process the mailbox was
      # shut for the whole boot, so await_boot always landed on the :running
      # clause after handle_continue returned and this path was dead code.
      task = Task.async(fn -> receive do: (msg -> msg) end)
      from = {task.pid, make_ref()}
      state = booting_state(boot_waiter: from)

      assert {:noreply, running} =
               VM.handle_info({:secrets_unlock_result, state.secrets_unlock_pid, :ok}, state)

      assert running.boot_waiter == nil
      assert {_ref, {:ok, %VM{state: :running}}} = Task.await(task, 1_000)
    end

    test "unlock bookkeeping is cleared so a late message cannot transition twice" do
      state = booting_state()

      assert {:noreply, running} =
               VM.handle_info({:secrets_unlock_result, state.secrets_unlock_pid, :ok}, state)

      assert running.secrets_unlock_ref == nil
      assert running.secrets_unlock_pid == nil
      assert running.secrets_unlock_timer == nil

      # The worker's :DOWN follows its result in the healthy case. With the ref
      # cleared it must fall through to the catch-all, not re-run finish_boot.
      down = {:DOWN, state.secrets_unlock_ref, :process, state.secrets_unlock_pid, :normal}
      assert {:noreply, ^running} = VM.handle_info(down, running)
    end

    test "a result from some other process is ignored" do
      state = booting_state(pid: spawn(fn -> :ok end))
      stray = {:secrets_unlock_result, self(), :ok}

      assert {:noreply, ^state} = VM.handle_info(stray, state)
      assert state.state == :booting
    end
  end

  describe "the worker dies" do
    test "a crash still completes the boot, recording the death" do
      # The worker's own try/catch converts ordinary failures into {:error, _},
      # so reaching here means it was killed uncatchably. Leaving the VM in
      # :booting would be worse than booting with a recorded failure.
      state = booting_state()
      down = {:DOWN, state.secrets_unlock_ref, :process, state.secrets_unlock_pid, :killed}

      assert {:noreply, running} = VM.handle_info(down, state)
      assert running.state == :running
      assert running.secrets_unlock_failure.reason =~ "unlock_worker_died"
    end
  end

  describe "the watchdog fires" do
    test "it kills the worker and waits for :DOWN rather than finishing twice" do
      worker = spawn(fn -> Process.sleep(:infinity) end)
      state = booting_state(pid: worker)

      assert {:noreply, unchanged} =
               VM.handle_info({:secrets_unlock_timeout, state.secrets_unlock_ref}, state)

      # Still booting: the kill produces a :DOWN, and THAT transitions the VM.
      # Finishing here as well would transition it twice.
      assert unchanged.state == :booting
      refute Process.alive?(worker)
    end

    test "a stale watchdog for a finished unlock is ignored" do
      running = %{booting_state() | state: :running, secrets_unlock_ref: nil}

      assert {:noreply, ^running} = VM.handle_info({:secrets_unlock_timeout, make_ref()}, running)
    end
  end
end
