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
  actions — either `{:resume, record, rootfs_path}` if the subvolume exists,
  or `{:missing_rootfs, record, expected_path}` if it doesn't.

  Extracted from `run/0` so unit tests can cover the decision logic without
  booting real VMs.
  """
  @spec build_plan([Record.t()]) :: [plan_entry()]
  def build_plan(records) do
    Enum.map(records, fn record ->
      path = rootfs_path(record.uuid)

      if File.exists?(path) do
        {:resume, record, path}
      else
        {:missing_rootfs, record, path}
      end
    end)
  end

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
