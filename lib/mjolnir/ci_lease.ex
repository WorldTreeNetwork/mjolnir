defmodule Mjolnir.CILease do
  @moduledoc """
  Server-side lease for CI-spawned VMs (mjolnir-urp).

  BACKGROUND: a forgejo-runner death (SIGKILL, host crash, OOM) bypasses
  in-process cleanup by construction, so client-side `Remove()`/`StopVM` can
  never be the only guarantee a job's VM gets torn down. Reproduced
  2026-08-12 (mjolnir-24r): systemd SIGKILLed a hung runner, the detached-
  context StopVM never fired, and `Mjolnir.Reconcile` then faithfully
  resumed the orphaned `:running` record forever — correct for a user VM,
  wrong for a job VM whose job no longer exists.

  MECHANISM: a CI-spawned VM (identified by `metadata["purpose"] == "ci"`,
  set by the forgejo-runner executor per mjolnir-cm2) carries
  `runtime["lease_expires_at"]` (unix seconds) in its `StateStore` record.
  Any VM-scoped API activity renews it via `renew/2`. `sweep/1` — piggybacked
  on the existing `Health.Monitor` 30s tick, right after `Reconcile.run/0`
  resumes any stranded record so a live GenServer exists to stop — reclaims
  every CI VM whose lease has expired by routing through the EXISTING
  `Mjolnir.VM.stop/1` teardown path, so the rootfs lands in `@trash`
  (recoverable) rather than being hard-deleted inline.

  SAFETY — this module destroys VMs, so eligibility fails closed on every
  ambiguous case: no `metadata` (or a `purpose` other than `"ci"`), no
  `lease_expires_at` recorded, or a lease that hasn't expired yet are all
  treated as NOT eligible, never as "assume it's fine". Absence of a signal
  must never be read as permission to reap.
  """

  require Logger

  alias Mjolnir.StateStore.Record

  @doc "Configured CI lease duration in seconds (`:ci_lease_seconds`, default 3600 = 1h)."
  @spec lease_seconds() :: pos_integer()
  def lease_seconds, do: Application.get_env(:mjolnir, :ci_lease_seconds, 3600)

  @doc """
  `true` iff `record` is positively tagged as CI-owned, i.e. its metadata map
  has `"purpose" => "ci"` exactly. No metadata, a missing `purpose` key, or
  any other `purpose` value all return `false` — this is the ownership gate
  and it must fail closed.
  """
  @spec ci_owned?(Record.t()) :: boolean()
  def ci_owned?(%Record{metadata: metadata}), do: ci_metadata?(metadata)
  def ci_owned?(_), do: false

  @doc """
  The same ownership gate as `ci_owned?/1`, against a raw metadata map — for
  callers that hold metadata before a `Record` exists (see `stamp_runtime/3`).
  """
  @spec ci_metadata?(map() | nil) :: boolean()
  def ci_metadata?(metadata) when is_map(metadata), do: Map.get(metadata, "purpose") == "ci"
  def ci_metadata?(_), do: false

  @doc """
  Stamp a freshly-built runtime map with a lease, if the VM is CI-owned.

  `Mjolnir.VM.build_running_record/1` rebuilds `runtime` from scratch on every
  boot AND every resume — deliberately, so counters like `resume_failures`
  reset on a successful resume. That means a lease written by `renew/2` does
  NOT survive a restart. Without stamping here, a leaked CI VM that outlives a
  Mjolnir restart would come back with no lease, and `eligible_for_reclaim?/2`
  fails closed on a missing lease, so it would become immortal — which is
  precisely how CI VMs accumulated in the first place (mjolnir-24r: durability
  "resurrects the orphaned :running record on every restart").

  Stamping at boot also covers the VM whose runner died before it ever issued
  an exec, which would otherwise never carry a lease at all.

  A fresh lease on resume is the right semantics, not a workaround: a VM that
  just came back is reclaimable one full lease later, exactly as if it had
  just been spawned.
  """
  @spec stamp_runtime(map(), map() | nil, integer()) :: map()
  def stamp_runtime(runtime, metadata, now \\ System.os_time(:second))

  def stamp_runtime(runtime, metadata, now) when is_map(runtime) do
    if ci_metadata?(metadata) do
      Map.put(runtime, "lease_expires_at", now + lease_seconds())
    else
      runtime
    end
  end

  def stamp_runtime(runtime, _metadata, _now), do: runtime

  @doc """
  The record's recorded lease expiry (unix seconds), or `nil` if absent or
  unparseable. `nil` must never be treated as "expired" by callers — see
  `eligible_for_reclaim?/2`.
  """
  @spec lease_expires_at(Record.t()) :: integer() | nil
  def lease_expires_at(%Record{runtime: runtime}) when is_map(runtime) do
    parse_timestamp(Map.get(runtime, "lease_expires_at"))
  end

  def lease_expires_at(_), do: nil

  defp parse_timestamp(n) when is_integer(n), do: n
  defp parse_timestamp(n) when is_float(n), do: trunc(n)

  defp parse_timestamp(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_timestamp(_), do: nil

  @doc """
  THE eligibility predicate. A record is eligible for reclamation only if it
  is positively CI-owned AND its lease is definitively in the past. Every
  other case — not CI-owned, no lease recorded, or a lease still valid — is
  NOT eligible. This must stay a strict AND: do not "optimise" it into
  reading absence of `lease_expires_at` as expired, and do not widen
  `ci_owned?/1` to match on anything besides an exact `"ci"` purpose.
  """
  @spec eligible_for_reclaim?(Record.t(), integer()) :: boolean()
  def eligible_for_reclaim?(%Record{} = record, now \\ System.os_time(:second)) do
    ci_owned?(record) and lease_expired?(record, now)
  end

  defp lease_expired?(record, now) do
    case lease_expires_at(record) do
      nil -> false
      expires_at -> now > expires_at
    end
  end

  @doc """
  Renew a CI VM's lease from VM-scoped API activity (exec, and other
  `/api/vms/:id/*` traffic — see call sites in `Mjolnir.API.Router`).

  No-op (returns `:ok`) if the VM has no StateStore record or is not
  CI-owned — renewal must never manufacture a lease for a VM that was never
  eligible for one.
  """
  @spec renew(String.t(), integer()) :: :ok | {:error, term()}
  def renew(vm_id, now \\ System.os_time(:second)) when is_binary(vm_id) do
    case Mjolnir.StateStore.get(vm_id) do
      {:ok, record} ->
        if ci_owned?(record) do
          runtime = Map.put(record.runtime || %{}, "lease_expires_at", now + lease_seconds())

          case Mjolnir.StateStore.put(%{record | runtime: runtime}) do
            :ok ->
              :ok

            {:error, reason} = err ->
              Logger.warning("CILease: failed to renew lease for #{vm_id}: #{inspect(reason)}")
              err
          end
        else
          :ok
        end

      :not_found ->
        :ok
    end
  end

  @doc """
  Reclaim every CI VM whose lease has expired, via the existing
  `Mjolnir.VM.stop/1` teardown path — never a direct/hard delete. Intended to
  be called from the periodic `Health.Monitor` tick, after
  `Mjolnir.Reconcile.run/0` has had a chance to resume any stranded record
  (a leaked CI VM has a `:running` record but no live GenServer until then).

  Returns the list of vm_ids it attempted to reclaim.
  """
  @spec sweep(integer()) :: [String.t()]
  def sweep(now \\ System.os_time(:second)) do
    Mjolnir.StateStore.list_by_metadata(%{"purpose" => "ci"})
    |> Enum.filter(&eligible_for_reclaim?(&1, now))
    |> Enum.map(&reclaim(&1, now))
  end

  defp reclaim(%Record{uuid: vm_id} = record, now) do
    expired_for = now - lease_expires_at(record)

    Logger.warning(
      "CILease: reclaiming CI VM #{vm_id} (metadata=#{inspect(record.metadata)}), " <>
        "lease expired #{expired_for}s ago"
    )

    case Mjolnir.VM.stop(vm_id) do
      :ok ->
        vm_id

      {:error, :not_found} ->
        Logger.warning(
          "CILease: VM #{vm_id} had no live GenServer to stop (already gone or not yet resumed)"
        )

        vm_id

      {:error, reason} ->
        Logger.error("CILease: failed to reclaim VM #{vm_id}: #{inspect(reason)}")
        vm_id
    end
  end
end
