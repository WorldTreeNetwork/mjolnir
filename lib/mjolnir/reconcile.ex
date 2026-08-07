defmodule Mjolnir.Reconcile do
  @moduledoc """
  Boot-time VM rehydration.

  Runs once during Mjolnir startup, after `Mjolnir.StateStore` is loaded and
  `Mjolnir.Cleanup.sweep/0` has pruned orphan subvolumes. For each record in
  StateStore with `intent: :running`, Reconcile re-spawns the VM in resume
  mode (see `Mjolnir.VM.resume/1`), preserving the rootfs subvolume and VM
  identity.

  Dormant VMs are NOT handled here — `Mjolnir.DormantRegistry` owns its own
  file-backed persistence and restores itself on start.

  ## Restart policy — when NOT to rehydrate (mjolnir-yhr)

  Rehydration is right for a VM the *host* lost: a BEAM restart, a hypervisor
  crash, an eviction. It is wrong for a VM that ended *itself*. Reconcile cannot
  tell those apart from the outside — both leave a `:running` record with no live
  hypervisor — so the distinction has to be declared up front, by whoever created
  the VM, as `restart_policy` in the spawn config:

  - `:always` (default) — today's behavior. A stranded record is resumed.
  - `:never` — a stranded record is **finalized**, not resumed: intent flips to
    `:stopped` and the rootfs subvolume is preserved. Nothing brings it back
    except an explicit, owner-initiated action (`Mjolnir.VM.revive/1`, or a
    fresh spawn from its snapshot).

  This is the substrate primitive Buzz remote agents need. `docs/remote-agents.md`
  invariant **I5** makes intentional termination terminal — an owner `!shutdown`
  or an inactivity reap must not be undone by the substrate — and
  `buzz-backend-mjolnir`'s L3 binding states it ships with no revive policy at
  all. Without `:never`, Mjolnir revived every agent that shut itself down,
  roughly seven seconds later, and that claim was false.

  Deliberately a **declared policy, not an inferred one.** Reconcile does not
  decide by reading anything the guest wrote: a body wedged badly enough to need
  reaping cannot write a marker, and a guest that *can* write one should not be
  the thing that decides whether the host may restart it. When a guest-written
  exit marker happens to be present it is recorded on the record as evidence for
  the operator (and for the provider's intentional-vs-abnormal reporting), and it
  changes no decision here.

  ## Failure modes

  - **Resume fails (boot timeout, CH crash, etc.)** — logged; the record's
    failure counter is bumped and it stays `:running` so the next reconcile
    pass retries.
  - **Record points to a missing subvolume** — logged; counts as a failure for
    retirement purposes (the data is gone, so it will never resume).

  ## Retirement (mjolnir-5fu)

  A record that can never boot again would otherwise be retried on every
  `Health.Monitor` tick and re-resumed on every server restart, accumulating as
  a "ghost VM". To stop that, each consecutive resume failure is recorded in the
  record's `runtime` map (`resume_failures`, `first_failure_at`,
  `last_failure_at`). Once a record has failed `:reconcile_max_failures` times
  in a row (default 10) **or** its failure streak is older than
  `:reconcile_failure_ttl_seconds` (default 24h), Reconcile flips its intent
  from `:running` to `:failed`. A `:failed` record is no longer resumed — but
  its rootfs subvolume is preserved (per the durability invariant), so it stays
  visible as `state=failed` in the API and can be revived (`Mjolnir.VM.revive/1`)
  or forgotten by an operator. A *successful* resume rewrites a fresh `:running`
  record via `Mjolnir.VM` boot, which clears the counter automatically.

  Because a resume-mode boot failure never re-persists the record (see
  `Mjolnir.VM`'s `handle_boot_failure/5`, guarded on `not resume_mode`),
  Reconcile is the sole writer on the failure path — the read-modify-write of
  the counter is race-free.
  """

  require Logger

  alias Mjolnir.StateStore
  alias Mjolnir.StateStore.Record

  @default_max_failures 10
  @default_failure_ttl_seconds 86_400

  @type plan_entry ::
          {:resume, Record.t(), rootfs_path :: String.t()}
          | {:missing_rootfs, Record.t(), expected_path :: String.t()}
          | {:finalize, Record.t(), rootfs_path :: String.t()}

  # Guest-written exit evidence, read from the stopped VM's subvolume when
  # finalizing a :never record. Non-decisional — see the moduledoc. Path is
  # relative to the rootfs; the cap is there because this is guest-controlled
  # content being read by the host.
  @harness_exit_rel_path "var/lib/buzz/harness-exit"
  @harness_exit_max_bytes 4_096

  @doc """
  Entrypoint called by the supervision tree at boot, and periodically by
  `Mjolnir.Health.Monitor`. Returns `:ok` once every record has been
  attempted.

  Idempotent: records whose VM is already registered in `Mjolnir.VMRegistry`
  are skipped silently. This lets the Monitor call `run/0` every tick
  without logging noise for the healthy case, while still catching any VM
  whose GenServer died mid-flight (e.g. after a hypervisor_exit).

  Resumes run with bounded concurrency (`:reconcile_max_concurrency`, default
  4) rather than one-at-a-time. Each `Mjolnir.VM.resume/1` blocks up to 60s on
  the VM's boot; serially that is `N × boot_time`, which on a fresh start with
  many stranded VMs is the difference between recovering in seconds vs. minutes
  (mjolnir-s8h). Per-VM resources (TAP, vsock CID, rootfs subvolume) are all
  derived from the UUID, so parallel resumes do not contend; the cap just keeps
  a large fleet from thundering-herding the host. In steady state the plan is
  empty and no tasks are spawned, so the Monitor's per-tick cost is unchanged.
  """
  @spec run() :: :ok
  def run do
    records = StateStore.list_by_intent(:running)
    stranded = Enum.reject(records, &vm_registered?/1)
    plan = build_plan(stranded)

    case plan do
      [] ->
        :ok

      entries ->
        max_concurrency = Application.get_env(:mjolnir, :reconcile_max_concurrency, 4)

        Logger.info(
          "Reconcile: rehydrating #{length(entries)} stranded VM(s) " <>
            "(max_concurrency=#{max_concurrency})"
        )

        entries
        |> Task.async_stream(&execute/1,
          max_concurrency: max_concurrency,
          # resume/1 has its own 60s await_boot timeout; don't let the stream's
          # default 5s timeout kill a still-booting VM out from under it.
          timeout: :infinity,
          ordered: false
        )
        |> Stream.run()
    end

    :ok
  end

  defp vm_registered?(%Record{uuid: uuid}) do
    case Registry.lookup(Mjolnir.VMRegistry, uuid) do
      [_ | _] -> true
      [] -> false
    end
  end

  @doc """
  Pure planning function: given a list of :running records, produce a list of
  actions:

  - `{:finalize, record, rootfs_path}` — `restart_policy: :never`. Not resumed;
    intent flips to `:stopped`. Checked **first**, ahead of the rootfs test,
    because the policy holds whether or not the data is still there.
  - `{:resume, record, rootfs_path}` — the subvolume exists.
  - `{:missing_rootfs, record, expected_path}` — it doesn't.

  Extracted from `run/0` so unit tests can cover the decision logic without
  booting real VMs.
  """
  @spec build_plan([Record.t()]) :: [plan_entry()]
  def build_plan(records) do
    Enum.map(records, fn record ->
      path = rootfs_path(record.uuid)

      cond do
        restart_policy(record) == :never -> {:finalize, record, path}
        File.exists?(path) -> {:resume, record, path}
        true -> {:missing_rootfs, record, path}
      end
    end)
  end

  @doc """
  The record's declared restart policy: `:never` or `:always` (the default).

  Read from `spawn_config["restart_policy"]`, which round-trips through
  `Mjolnir.StateStore` already — so this needed no record schema bump and no
  migration. Anything unrecognised reads as `:always`: an unparseable policy must
  not silently become "never restart this VM", which would strand a fleet on a
  typo.
  """
  @spec restart_policy(Record.t()) :: :always | :never
  def restart_policy(%Record{spawn_config: cfg}) when is_map(cfg) do
    case Map.get(cfg, "restart_policy") do
      "never" -> :never
      _ -> :always
    end
  end

  def restart_policy(_), do: :always

  @doc """
  Computes the expected rootfs path for a given VM UUID.
  """
  @spec rootfs_path(String.t()) :: String.t()
  def rootfs_path(uuid) do
    btrfs_root = Application.fetch_env!(:mjolnir, :btrfs_root)
    subdir = Application.get_env(:mjolnir, :vm_storage_subdir, "@vms")
    Path.join([btrfs_root, subdir, uuid])
  end

  defp execute({:resume, %Record{uuid: uuid} = record, _path}) do
    # resume/1 blocks on `GenServer.call(:await_boot, 60_000)`, which *exits*
    # (not returns an error) on timeout. Because we run under Task.async_stream,
    # an un-caught exit would propagate and abort every other VM's resume in the
    # batch — so isolate each VM: a single stuck boot is logged and the record
    # is left :running for the next pass, exactly like a returned {:error, _}.
    try do
      case Mjolnir.VM.resume(record) do
        {:ok, _vm} ->
          Logger.info("Reconcile: VM #{uuid} resumed")

        {:error, reason} ->
          record_failure(record, "resume failed: #{inspect(reason)}")
      end
    catch
      kind, reason ->
        record_failure(record, "resume #{kind}: #{inspect(reason)}")
    end
  end

  # restart_policy: :never — the VM is gone and stays gone. Flip intent to
  # :stopped so it drops out of the stranded set instead of being re-examined on
  # every Health.Monitor tick, and preserve the rootfs: for a Buzz agent that
  # subvolume IS the agent's desk (checkout, working tree, half-finished edit),
  # and snapshot-resume on the next owner-initiated Start clones from it.
  defp execute({:finalize, %Record{uuid: uuid} = record, path}) do
    exit_evidence = read_harness_exit(path)

    runtime =
      (record.runtime || %{})
      |> Map.put("finalized_at", DateTime.to_iso8601(DateTime.utc_now()))
      |> Map.put("finalized_reason", "restart_policy=never")
      |> Map.merge(exit_evidence)

    updated = %{record | intent: :stopped, runtime: runtime}

    Logger.info(
      "Reconcile: VM #{uuid} has restart_policy=never — not resuming. " <>
        "Intent set to :stopped, rootfs preserved at #{path}." <>
        describe_exit(exit_evidence)
    )

    case StateStore.put(updated) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Reconcile: failed to finalize #{uuid}: #{inspect(reason)}")
    end
  end

  defp execute({:missing_rootfs, %Record{uuid: uuid} = record, path}) do
    record_failure(
      record,
      "rootfs missing at #{path} (data lost — cannot resume)",
      fn -> "Reconcile: VM #{uuid} rootfs is gone; " end
    )
  end

  # Bump the record's consecutive-failure counter and, if it crosses the
  # retirement threshold, flip its intent to `:failed` so it stops being
  # resumed every tick. Persistence failures here are non-fatal: the worst case
  # is the counter doesn't advance this pass and we retry again next tick.
  defp record_failure(record, why, prefix \\ nil) do
    {disposition, updated} = note_failure(record)
    prefix = if prefix, do: prefix.(), else: "Reconcile: VM #{record.uuid} "

    case disposition do
      :retire ->
        Logger.error(
          prefix <>
            "#{why}. Retired after #{updated.runtime["resume_failures"]} failed attempt(s) — " <>
            "intent set to :failed, rootfs preserved. Revive with " <>
            "`POST /api/vms/#{record.uuid}/revive` once the cause is fixed."
        )

      :retry ->
        Logger.warning(
          prefix <>
            "#{why}. Attempt #{updated.runtime["resume_failures"]}/#{max_failures()}; " <>
            "record kept :running for the next reconcile pass."
        )
    end

    case StateStore.put(updated) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Reconcile: failed to persist failure for #{record.uuid}: #{inspect(reason)}"
        )
    end
  end

  @doc """
  Pure retirement policy: given a `:running` record (and optionally the current
  time), return `{disposition, updated_record}` where `disposition` is
  `:retire` (intent flipped to `:failed`) or `:retry` (intent unchanged).

  The updated record always carries an incremented `runtime["resume_failures"]`
  counter plus `first_failure_at`/`last_failure_at` timestamps. Extracted as a
  pure function so the count/TTL thresholds can be unit-tested without booting
  VMs or touching disk.
  """
  @spec note_failure(Record.t(), DateTime.t()) :: {:retire | :retry, Record.t()}
  def note_failure(%Record{} = record, now \\ DateTime.utc_now()) do
    runtime = record.runtime || %{}
    failures = (runtime["resume_failures"] || 0) + 1
    first_at = runtime["first_failure_at"] || DateTime.to_iso8601(now)
    now_iso = DateTime.to_iso8601(now)

    runtime =
      runtime
      |> Map.put("resume_failures", failures)
      |> Map.put("first_failure_at", first_at)
      |> Map.put("last_failure_at", now_iso)

    streak_seconds = failure_streak_seconds(first_at, now)

    if failures >= max_failures() or streak_seconds >= failure_ttl_seconds() do
      {:retire, %{record | intent: :failed, runtime: runtime}}
    else
      {:retry, %{record | runtime: runtime}}
    end
  end

  @doc """
  Read the guest-written harness exit marker out of a stopped VM's rootfs, if it
  left one.

  Returns a `runtime`-shaped map with `harness_exit_reason` / `harness_exit_status`
  / `harness_service_result`, or `%{}` when there is no marker — which is the
  common case and not an error: only bodies built from `@base/buzz-agent` write
  one, and a wedged body writes nothing at all.

  **This never decides anything.** It is evidence for the operator and for the
  provider's I5 intentional-vs-abnormal reporting (`exited`/`0` is intentional;
  anything else abnormal). The decision not to restart came from the declared
  `restart_policy`, before this file was even opened. Guest-controlled content,
  so the read is size-capped and only the three known keys are kept.
  """
  @spec read_harness_exit(String.t()) :: %{String.t() => String.t()}
  def read_harness_exit(rootfs_path) do
    path = Path.join(rootfs_path, @harness_exit_rel_path)

    with {:ok, %File.Stat{size: size}} when size <= @harness_exit_max_bytes <- File.stat(path),
         {:ok, contents} <- File.read(path) do
      contents
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          ["exit_reason", v] -> Map.put(acc, "harness_exit_reason", String.trim(v))
          ["exit_status", v] -> Map.put(acc, "harness_exit_status", String.trim(v))
          ["service_result", v] -> Map.put(acc, "harness_service_result", String.trim(v))
          _ -> acc
        end
      end)
    else
      _ -> %{}
    end
  end

  defp describe_exit(%{"harness_exit_reason" => "exited", "harness_exit_status" => "0"}),
    do: " Harness exited cleanly (0) — intentional termination."

  defp describe_exit(%{"harness_exit_reason" => reason, "harness_exit_status" => status}),
    do: " Harness died abnormally (#{reason}/#{status})."

  defp describe_exit(_), do: ""

  defp failure_streak_seconds(first_at_iso, now) do
    case DateTime.from_iso8601(first_at_iso) do
      {:ok, first, _} -> DateTime.diff(now, first, :second)
      _ -> 0
    end
  end

  defp max_failures,
    do: Application.get_env(:mjolnir, :reconcile_max_failures, @default_max_failures)

  defp failure_ttl_seconds,
    do:
      Application.get_env(:mjolnir, :reconcile_failure_ttl_seconds, @default_failure_ttl_seconds)
end
