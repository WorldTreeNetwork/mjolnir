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

  - **Record points to a missing subvolume** — logged; record is left in place
    so a human can investigate. Does not block other VMs from rehydrating.
  - **Resume fails (boot timeout, CH crash, etc.)** — logged; record stays
    `:running` so the next reconcile pass retries.
  """

  require Logger

  alias Mjolnir.StateStore
  alias Mjolnir.StateStore.Record

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
          Logger.error(
            "Reconcile: VM #{uuid} resume failed: #{inspect(reason)}. " <>
              "Record left as :running; next reconcile will retry."
          )
      end
    catch
      kind, reason ->
        Logger.error(
          "Reconcile: VM #{uuid} resume #{kind}: #{inspect(reason)}. " <>
            "Record left as :running; next reconcile will retry."
        )
    end
  end

  defp execute({:missing_rootfs, %Record{uuid: uuid}, path}) do
    Logger.warning(
      "Reconcile: VM #{uuid} has :running record but rootfs is missing at #{path}. " <>
        "Record kept for manual investigation — inspect with `mj info <id>` " <>
        "or delete via StateStore.delete/1 if known-lost."
    )
  end
end
