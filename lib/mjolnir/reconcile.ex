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
  Entrypoint called by the supervision tree. Returns `:ok` once every record
  has been attempted.
  """
  @spec run() :: :ok
  def run do
    plan = build_plan(StateStore.list_by_intent(:running))

    case plan do
      [] ->
        Logger.info("Reconcile: no running-intent records, nothing to rehydrate")

      entries ->
        Logger.info("Reconcile: rehydrating #{length(entries)} VM(s) from StateStore")
        Enum.each(entries, &execute/1)
    end

    :ok
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
    case Mjolnir.VM.resume(record) do
      {:ok, _vm} ->
        Logger.info("Reconcile: VM #{uuid} resumed")

      {:error, reason} ->
        Logger.error(
          "Reconcile: VM #{uuid} resume failed: #{inspect(reason)}. " <>
            "Record left as :running; next reconcile will retry."
        )
    end
  end

  defp execute({:missing_rootfs, %Record{uuid: uuid}, path}) do
    Logger.warning(
      "Reconcile: VM #{uuid} has :running record but rootfs is missing at #{path}. " <>
        "Record kept for manual investigation — inspect with `just vm-info` " <>
        "or delete via StateStore.delete/1 if known-lost."
    )
  end
end
