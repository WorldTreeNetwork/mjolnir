defmodule Mjolnir.AIE.OccupancyTest do
  use ExUnit.Case, async: false

  alias Mjolnir.AIE.Occupancy

  setup do
    pid = start_supervised!({Occupancy, admit_deadline_ms: 5_000})
    {:ok, occ: pid}
  end

  test "second try-lock is occupied until release", %{occ: occ} do
    assert {:ok, %{attempt_id: a1}} = Occupancy.try_lock(occ, [])
    assert {:error, :occupied} = Occupancy.try_lock(occ, [])
    assert Occupancy.holding?(occ)
    assert :ok = Occupancy.release(occ, a1)
    assert {:ok, %{attempt_id: a2}} = Occupancy.try_lock(occ, [])
    refute a1 == a2
  end

  test "guest xclbin is refused at load", %{occ: occ} do
    {:ok, %{attempt_id: att}} = Occupancy.try_lock(occ, [])
    :ok = Occupancy.mark_live_success(occ, att, "pnd_1")

    assert {:error, :unknown_design} =
             Occupancy.authorize_load(occ, "pnd_1", att, design_id: "/tmp/guest.xclbin")

    assert {:error, :unknown_design} =
             Occupancy.authorize_load(occ, "pnd_1", att, design_id: "evil.xclbin")

    assert Occupancy.guest_xclbin?("payload.xclbin")
    refute Occupancy.accepted_design?("payload.xclbin")
  end

  test "lost reply on a live attempt may load once", %{occ: occ} do
    {:ok, %{attempt_id: att}} = Occupancy.try_lock(occ, [])
    :ok = Occupancy.mark_live_success(occ, att, "pnd_live")
    assert :ok = Occupancy.authorize_load(occ, "pnd_live", att, design_id: "vector-add")

    assert {:error, :already_loaded} =
             Occupancy.authorize_load(occ, "pnd_live", att, design_id: "vector-add")
  end

  test "abandoned attempt cannot load even with historical dispatched", %{occ: occ} do
    {:ok, %{attempt_id: att}} = Occupancy.try_lock(occ, [])
    :ok = Occupancy.mark_live_success(occ, att, "pnd_old")
    :ok = Occupancy.abandon(occ, att)
    assert Occupancy.historical?(occ, "pnd_old", att)

    assert {:error, :abandoned} =
             Occupancy.authorize_load(occ, "pnd_old", att, design_id: "vector-add")
  end

  test "late success after abandon does not load", %{occ: occ} do
    {:ok, %{attempt_id: att}} = Occupancy.try_lock(occ, [])
    :ok = Occupancy.abandon(occ, att)
    assert {:error, reason} = Occupancy.mark_live_success(occ, att, "pnd_late")
    assert reason in [:abandoned, :wrong_attempt]

    assert {:error, :abandoned} =
             Occupancy.authorize_load(occ, "pnd_late", att, design_id: "vector-add")
  end

  test "same pending_id cannot authorize a later occupancy attempt", %{occ: occ} do
    {:ok, %{attempt_id: att}} = Occupancy.try_lock(occ, [])
    :ok = Occupancy.mark_live_success(occ, att, "pnd_once")
    :ok = Occupancy.authorize_load(occ, "pnd_once", att, design_id: "vector-add")
    :ok = Occupancy.release(occ, att)

    {:ok, %{attempt_id: att2}} = Occupancy.try_lock(occ, [])
    :ok = Occupancy.mark_live_success(occ, att2, "pnd_once")

    assert {:error, :already_loaded} =
             Occupancy.authorize_load(occ, "pnd_once", att2, design_id: "vector-add")
  end

  test "wall time kills the worker and releases after quiescence", %{occ: occ} do
    {:ok, %{attempt_id: att}} = Occupancy.try_lock(occ, [])
    :ok = Occupancy.mark_live_success(occ, att, "pnd_w")
    :ok = Occupancy.authorize_load(occ, "pnd_w", att, design_id: "vector-add")

    :ok =
      Occupancy.start_worker(
        occ,
        att,
        fn -> Process.sleep(10_000) end,
        wall_ms: 30
      )

    assert :ok = Occupancy.await_quiescence(occ, att, 1_000)
    refute Occupancy.holding?(occ)
  end

  test "locator omitted without device or unit" do
    prev_path = Application.get_env(:mjolnir, :aie_device_path)
    prev_unit = Application.get_env(:mjolnir, :aie_unit_active)
    Application.put_env(:mjolnir, :aie_device_path, "/no/such/accel0")
    Application.put_env(:mjolnir, :aie_unit_active, true)

    on_exit(fn ->
      restore(:aie_device_path, prev_path)
      restore(:aie_unit_active, prev_unit)
    end)

    refute Mjolnir.AIE.Sidecar.available?()
    assert Mjolnir.AIE.Sidecar.locator_url() == nil
  end

  test "locator present when device exists and unit is up" do
    prev_path = Application.get_env(:mjolnir, :aie_device_path)
    prev_unit = Application.get_env(:mjolnir, :aie_unit_active)
    path = Path.join(System.tmp_dir!(), "accel-#{System.unique_integer([:positive])}")
    File.touch!(path)
    Application.put_env(:mjolnir, :aie_device_path, path)
    Application.put_env(:mjolnir, :aie_unit_active, true)

    on_exit(fn ->
      File.rm(path)
      restore(:aie_device_path, prev_path)
      restore(:aie_unit_active, prev_unit)
    end)

    assert Mjolnir.AIE.Sidecar.available?()
    assert Mjolnir.AIE.Sidecar.locator_url() == "http://10.200.0.1:7422"
  end

  test "try-lock refuses a live worker that did not inherit the flock", %{occ: occ} do
    # This process is alive; treat it as a persisted worker pid without inherit.
    fake_pid = 1

    if File.exists?("/proc/1") do
      assert {:error, :live_worker} =
               Occupancy.try_lock(occ,
                 persisted_worker_pid: fake_pid,
                 inherited_flock?: false
               )
    end

    assert {:ok, _} =
             Occupancy.try_lock(occ,
               persisted_worker_pid: fake_pid,
               inherited_flock?: true
             )
  end

  defp restore(key, nil), do: Application.delete_env(:mjolnir, key)
  defp restore(key, value), do: Application.put_env(:mjolnir, key, value)
end
