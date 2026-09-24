defmodule Mjolnir.VM do
  @moduledoc """
  MicroVM lifecycle management.

  Spawns microVMs via pluggable hypervisor backends (Cloud Hypervisor default)
  with BTRFS-backed filesystems and provides command execution via vsock.
  """

  use GenServer, restart: :transient
  require Logger

  alias Mjolnir.BTRFS

  defstruct [
    :id,
    :config,
    :hypervisor,
    :hypervisor_pid,
    :hypervisor_port,
    :socket_path,
    :vsock_path,
    :vsock_conn,
    :serial_path,
    :rootfs_path,
    :virtiofsd_port,
    :extra_virtiofsd_ports,
    :net_config,
    :state,
    :boot_time,
    # Iroh shell support
    :iroh_node_id,
    :iroh_json,
    :ticket,
    :pty_ready,
    # Ownership (multi-tenancy)
    :owner_id,
    # SSH key injection
    :ssh_public_key,
    # Iroh networking toggle
    enable_iroh: false,
    # Secrets mode: :none (default) | :ephemeral (RAM-only) |
    # :persistent (LUKS, passphrase held by remote Iroh peer — refuses dormancy) |
    # :managed (LUKS, passphrase escrowed by host — host re-injects on boot/wake,
    # so dormancy works). See docs/secrets-architecture.md → "Managed Mode".
    secrets_mode: :none,
    # Transient secret material (KEY=>VALUE) delivered on first :managed inject.
    # Never persisted — the content ends up encrypted inside the LUKS volume.
    secrets_payload: nil,
    # Inter-VM message queue (buffered during boot)
    message_queue: [],
    # Resume mode: true when booting an existing VM from StateStore (skips
    # rootfs clone + guest agent re-injection). Set by Mjolnir.Reconcile.
    resume_mode: false,
    # Opaque string=>string labels supplied at spawn. Mjolnir never interprets
    # them; they let an external orchestrator select and positively identify the
    # VMs it created. Carried into the first StateStore record so there is no
    # window where a created VM exists unlabelled — a crash in that window would
    # strand a VM its creator can no longer recognise as its own.
    metadata: %{},
    # Monitor refs of exec Tasks currently running against this VM.
    #
    # A guest busy with a long command is the HEALTHIEST possible state, but it
    # answers health probes slowly (a `cp -a` of 139MB plus a bundler saturates
    # 2 vCPUs), so Health.Monitor used to declare it unreachable and "heal" it —
    # and the L1 heal stops the very Vsock.Connection the in-flight exec is
    # blocked on, killing the operation it was trying to rescue. Health reads
    # this to distinguish BUSY from DEAD (mjolnir-1s9).
    exec_inflight: %{},
    # `from` tuples waiting on an in-flight `rebuild_vsock_connection` (mjolnir-
    # 75d). Rebuild MUTATES `vsock_conn`, so unlike the read-only round trips
    # above it cannot just spawn-and-reply from the worker process — the new
    # Connection pid has to land in *this* GenServer's state, from *this*
    # process. A second caller arriving while a rebuild is already in flight
    # piggybacks here instead of racing a second rebuild.
    vsock_rebuild_waiters: [],
    # Monitor ref for the in-flight rebuild worker. Without it, a worker that
    # dies UNCATCHABLY (Process.exit/2 with :kill — try/catch cannot see it)
    # would never send its result, leaving waiters queued forever and every
    # later rebuild piggybacking onto a queue that can never drain. That is a
    # permanent wedge of the un-wedging path, which is the one thing this
    # whole change exists to prevent. The DOWN clause uses this to fail the
    # waiters instead.
    vsock_rebuild_ref: nil,
    # Lifetime policy (mjolnir-yhr). :always (default) lets Mjolnir.Reconcile
    # rehydrate this VM if it is found stranded — right when the HOST lost it.
    # :never means a stranded record is finalized to :stopped instead, rootfs
    # preserved, and only an explicit owner-initiated action starts it again.
    #
    # :never exists because Reconcile cannot tell "the host lost the VM" from
    # "the guest ended itself" — both look identical from outside — so the
    # creator has to declare it. Required by Buzz invariant I5 (intentional
    # termination is terminal); see Mjolnir.Reconcile's moduledoc.
    restart_policy: :always,
    # secrets_mode: :managed unlock outcome for the CURRENT boot (mjolnir-3v2).
    # `nil` when unlock is not applicable (non-:managed) or it succeeded/was
    # skipped. On failure: `%{reason: inspect(term), at: DateTime.t()}`.
    #
    # This is deliberately carried on the struct rather than written straight
    # into a StateStore record: `build_running_record/1` rebuilds `runtime`
    # from scratch on every boot AND resume (same reason CILease.stamp_runtime
    # exists), so anything written elsewhere would be silently wiped on the
    # very next boot. Set by finish_boot/2 from the unlock task's result, then
    # stamped into `runtime` inside build_running_record/1 — mirrors how
    # Mjolnir.CILease carries its lease.
    secrets_unlock_failure: nil,
    # The managed-secrets unlock runs OFF this process (mjolnir-y32). do_boot
    # used to perform it inline, and its 60s vsock bound held the mailbox shut
    # for the whole window — long enough for Health.Monitor's probe to time out
    # and render a perfectly healthy VM as `unreachable` on every deploy.
    #
    # While these are set the VM is still `:booting`: it answers calls, but has
    # not yet transitioned to `:running`. That ordering is load-bearing —
    # `:running` must keep meaning "the secrets volume is mounted", because
    # Mjolnir.Deploy.Orchestrator spawns a :managed VM and then starts an app
    # that sources /run/mjolnir/secrets.env.
    secrets_unlock_ref: nil,
    secrets_unlock_pid: nil,
    secrets_unlock_timer: nil,
    # Caller of `await_boot` parked while state is :booting, replied by
    # finish_boot/2. Was previously Map.put/3'd onto the struct and never
    # answered — dead code only because the inline boot never opened the
    # mailbox. Deferring the unlock makes that path live, so it is a real
    # field now and spawn/1 depends on the reply.
    boot_waiter: nil,
    # Named memory snapshot this GenServer is thawing from (`nil` on a
    # normal spawn). Set by `thaw/1` via spawn_with_id.
    thaw_name: nil
  ]

  @config_key_allowlist ~w(vcpus memory_mb enable_iroh ssh_public_key owner_id snapshot preserve_iroh_key secrets_mode extra_mounts restart_policy)

  # await_boot blocks the caller until do_boot completes. Non-managed boots are
  # comfortably under 30s. A :managed secrets boot ALSO creates/opens a LUKS
  # volume over vsock during do_boot (dd + argon2id luksFormat + mkfs), which
  # regularly pushes total boot past 30s and stranded an appless VM even though
  # the guest itself reached multi-user.target fine. Managed spawns therefore
  # get a longer default; any caller can override via the :await_boot_timeout
  # spawn opt. See await_boot_timeout/1.
  @default_await_boot_timeout 30_000
  @managed_await_boot_timeout 90_000

  # Generous but BOUNDED default for `exec/3` (mjolnir-8ie). A fixed short
  # timeout is wrong — CI builds legitimately run for many minutes — but
  # `:infinity` means a wedged guest pins the caller forever. Callers who
  # genuinely need no bound pass `timeout: :infinity` explicitly.
  @default_exec_timeout 900_000

  # Internal housekeeping commands the VM runs on its own behalf (e.g. the
  # pre-snapshot `sync`). These are never long-running, so a short bound is
  # right: if the guest can't answer in 30s it is wedged, and we want to find
  # that out instead of blocking the caller mid-snapshot.
  @internal_exec_timeout 30_000

  @type t :: %__MODULE__{}
  @type vm_id :: String.t()
  @type extra_mount :: %{
          required(:tag) => String.t(),
          required(:shared_dir) => String.t(),
          optional(:opts) => keyword()
        }

  @type spawn_opts :: %{
          optional(:base_image) => String.t(),
          optional(:vcpus) => pos_integer(),
          optional(:memory_mb) => pos_integer(),
          optional(:ssh_public_key) => String.t(),
          optional(:snapshot) => String.t(),
          optional(:preserve_iroh_key) => boolean(),
          optional(:enable_iroh) => boolean(),
          optional(:owner_id) => String.t() | nil,
          optional(:extra_mounts) => list(extra_mount()),
          optional(:secrets_mode) => :none | :ephemeral | :persistent | :managed,
          optional(:identity) => Mjolnir.Identity.t(),
          optional(:git_signing) => boolean(),
          optional(:restart_policy) => :always | :never,
          optional(:await_boot_timeout) => timeout(),
          optional(:id) => vm_id(),
          optional(:thaw) => String.t()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Spawn a new MicroVM.

  ## Options

  - `:base_image` - Base image name (default: "ubuntu-24.04"; other option: "arch")
  - `:vcpus` - Number of vCPUs (default: 2)
  - `:memory_mb` - Memory in MiB (default: 512)
  - `:snapshot` - Snapshot name to spawn from (instead of base image)
  - `:preserve_iroh_key` - Keep the iroh key from snapshot (default: false)
  - `:owner_id` - Owner recorded on the VM (drives API owner-scoping). Persisted
    on the VM state/record so `/api/vms/:id/exec` owner checks see it.
  - `:extra_mounts` - Extra virtiofs shares as
    `[%{tag: "src", shared_dir: "/host/dir", opts: []}]`. Each starts an extra
    virtiofsd. The guest-side mount is the caller's responsibility on a plain
    base image: `mount -t virtiofs <tag> <path>`.
  - `:await_boot_timeout` - How long `spawn/1` waits for boot to complete
    (default: 30s; auto-raised to #{@managed_await_boot_timeout}ms for
    `secrets_mode: :managed`, whose LUKS setup runs during boot).
  - `:identity` - `%{private_key_nsec: nsec, relay_url: url}` stored in
    SecretStore and injected over vsock to `/run/mjolnir/buzz.env`. The nsec
    is never kept on this struct or written to StateStore.
  - `:restart_policy` - `:always` (default) or `:never`. `:never` stops
    `Mjolnir.Reconcile` from rehydrating this VM if it is later found stranded;
    the record is finalized to `:stopped` with the rootfs preserved. Use it for
    any workload where the guest may legitimately end itself and must stay
    ended — see `Mjolnir.Reconcile`'s moduledoc.

  ## Examples

      {:ok, vm} = Mjolnir.VM.spawn(%{base_image: "ubuntu-24.04", memory_mb: 1024})
      {:ok, vm} = Mjolnir.VM.spawn(%{snapshot: "my-snapshot", preserve_iroh_key: true})
  """
  @spec spawn(spawn_opts()) :: {:ok, t()} | {:error, term()}
  def spawn(opts \\ %{}) do
    with :ok <- reject_memory_snapshot_spawn(opts),
         :ok <- reject_live_iroh_identity(opts) do
      do_spawn(Map.put(opts, :id, UUID.uuid4()))
    end
  end

  # preserve_iroh_key keeps the snapshot's node id so the ticket URL stays
  # put. A second running guest with that same key makes the relay drop
  # both ("another endpoint connected with the same endpoint id").
  defp reject_live_iroh_identity(%{preserve_iroh_key: true, snapshot: snapshot} = _opts)
       when is_binary(snapshot) do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    snap_key = Path.join([btrfs_root, "@snapshots", snapshot, "etc/mjolnir/iroh.key"])

    case File.read(snap_key) do
      {:ok, bytes} ->
        holder =
          list()
          |> Enum.filter(&(&1.state == :running and is_binary(&1.rootfs_path)))
          |> Enum.map(& &1.rootfs_path)
          |> then(&Mjolnir.BTRFS.find_rootfs_with_iroh_key(bytes, &1))

        case holder && Enum.find(list(), &(&1.rootfs_path == holder)) do
          nil -> :ok
          vm -> {:error, {:iroh_identity_in_use, vm.id, vm.ticket}}
        end

      _ ->
        :ok
    end
  end

  defp reject_live_iroh_identity(_opts), do: :ok

  defp do_spawn(opts) do
    vm_id = opts.id

    case DynamicSupervisor.start_child(
           Mjolnir.VMSupervisor,
           {__MODULE__, Map.put(opts, :id, vm_id)}
         ) do
      {:ok, pid} ->
        # Wait for boot to complete
        case GenServer.call(pid, :await_boot, await_boot_timeout(opts)) do
          {:ok, vm} -> {:ok, vm}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Resolve the await_boot timeout from spawn opts. Explicit :await_boot_timeout
  # wins; otherwise :managed secrets get the longer default (LUKS setup happens
  # inside do_boot, before the boot is signalled complete). Everything else keeps
  # the historical 30s.
  defp await_boot_timeout(opts) do
    cond do
      is_integer(opts[:await_boot_timeout]) -> opts[:await_boot_timeout]
      opts[:await_boot_timeout] == :infinity -> :infinity
      is_binary(opts[:thaw]) -> max(180_000, @managed_await_boot_timeout)
      opts[:secrets_mode] == :managed -> @managed_await_boot_timeout
      true -> @default_await_boot_timeout
    end
  end

  @doc """
  Execute a command in the guest and return its output.

  `:timeout` (default #{@default_exec_timeout}ms) bounds how long the guest may
  take to reply; `:infinity` opts out for genuinely unbounded work like CI
  builds. The bound is applied to the *vsock request itself*, not just to the
  surrounding `GenServer.call` — see `handle_call({:exec, ...})` for why that
  distinction is the whole bug in mjolnir-8ie.
  """
  @spec exec(vm_id(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def exec(vm_id, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_exec_timeout)
    GenServer.call(via_tuple(vm_id), {:exec, command, timeout}, outer_call_timeout(timeout))
  end

  # Keep the caller's GenServer.call strictly longer than the inner vsock bound
  # so the inner timeout always wins the race and returns {:error, :timeout},
  # rather than the caller exiting out from under an in-flight request. Mirrors
  # Mjolnir.Vsock.Connection.outer_timeout/1.
  defp outer_call_timeout(:infinity), do: :infinity
  defp outer_call_timeout(timeout) when is_integer(timeout), do: timeout + 10_000

  @doc """
  Get the current status of a VM.
  """
  @spec status(vm_id()) :: :booting | :running | :stopped | {:error, :not_found}
  def status(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, :status)
        catch
          :exit, _ -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Get the full VM state including configuration and metadata.
  """
  @spec get(vm_id()) :: {:ok, t()} | {:error, :not_found | :unreachable}
  def get(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        try do
          {:ok,
           GenServer.call(
             pid,
             :get_state,
             Application.get_env(:mjolnir, :vm_get_probe_timeout_ms, 5000)
           )}
        catch
          # A registered-but-blocked GenServer (e.g. mailbox wedged on a stuck
          # vsock exec after a snapshot pause/resume — mjolnir-8ie) is NOT a 404.
          # Return :unreachable so authz/API map it to a 5xx instead of falsely
          # reporting the VM as gone, which previously broke `mj kill`.
          :exit, _ -> {:error, :unreachable}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Stop a VM gracefully.
  """
  @spec stop(vm_id()) :: :ok | {:error, term()}
  def stop(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        timeout = Application.get_env(:mjolnir, :vm_stop_timeout_ms, 10_000)

        try do
          GenServer.stop(pid, :normal, timeout)
        catch
          # A wedged guest can leave the VM GenServer's mailbox blocked on an
          # :infinity vsock exec, so a graceful stop never returns and `mj kill`
          # hangs forever (mjolnir-8ie). Degrade to the same OS-level force-kill
          # reboot/1 uses: killing the cloud-hypervisor process makes the
          # GenServer terminate via its preserve-rootfs `{:hypervisor_exit, _}`
          # path, cleaning up TAP/virtiofsd/sockets even when the mailbox is
          # blocked. `:noproc` (already gone) also lands here and is a success.
          :exit, reason ->
            Logger.warning(
              "VM #{vm_id}: graceful stop failed (#{inspect(reason)}); force-killing hypervisor"
            )

            _ = kill_hypervisor_process(vm_id)
            :ok
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Create a named snapshot of a running VM's filesystem.

  Quiesces the VM (sync + pause), takes a consistent reflink copy,
  then resumes the VM. The VM is always resumed even if the snapshot fails.

  ## Options

    - `:owner_id` — owner recorded on the snapshot metadata.
    - `:skip_verify` — when `true`, skip the post-snapshot live-guest health
      probe (`:guest_unreachable_after_snapshot`). Intended for a VM that is
      about to be discarded (e.g. the final layer of a deploy build), where a
      post-snapshot guest hiccup should not fail an otherwise-intact snapshot.
      Do NOT set this if the same VM will keep being exec'd afterwards.

  ## Examples

      {:ok, metadata} = Mjolnir.VM.snapshot(vm_id, "my-node-env")
  """
  @spec snapshot(vm_id(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def snapshot(vm_id, name, opts \\ []) do
    GenServer.call(via_tuple(vm_id), {:snapshot, name, opts}, 60_000)
  end

  @doc """
  Park a running VM: capture RAM + filesystem as `name`, then stop the source.

  This is a one-way park. The VM does not keep serving. Restore with `thaw/1`.
  """
  @spec freeze(vm_id(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def freeze(vm_id, name, opts \\ []) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        GenServer.call(pid, {:freeze, name, opts}, 300_000)

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Restore a memory snapshot into the original VM id recorded at freeze.
  """
  @spec thaw(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def thaw(name, opts \\ []) do
    with {:ok, %{metadata: meta}} <- BTRFS.get_snapshot(name),
         :ok <- ensure_memory_snapshot(name),
         vm_id when is_binary(vm_id) <-
           meta[:source_vm_id] || {:error, :missing_source_vm_id},
         :ok <- ensure_id_free(vm_id) do
      spawn_opts = thaw_spawn_opts(meta, vm_id, name, opts)

      try do
        spawn_with_id(spawn_opts)
      catch
        :exit, reason -> {:error, {:thaw_failed, reason}}
      end
    end
  end

  defp ensure_memory_snapshot(name) do
    if Mjolnir.MemorySnapshot.memory_snapshot?(name) do
      :ok
    else
      {:error, :not_a_memory_snapshot}
    end
  end

  defp ensure_id_free(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [] -> :ok
      _ -> {:error, {:vm_running, vm_id, :registered}}
    end
  end

  defp thaw_spawn_opts(meta, vm_id, name, opts) do
    cfg = meta[:restore_config] || meta["restore_config"] || %{}

    %{
      id: vm_id,
      thaw: name,
      owner_id: Keyword.get(opts, :owner_id, meta[:owner_id]),
      base_image: cfg_get(cfg, :base_image),
      vcpus: cfg_get(cfg, :vcpus),
      memory_mb: cfg_get(cfg, :memory_mb),
      enable_iroh: cfg_get(cfg, :enable_iroh),
      ssh_public_key: cfg_get(cfg, :ssh_public_key),
      secrets_mode: normalize_secrets_mode(cfg_get(cfg, :secrets_mode)),
      restart_policy: normalize_restart_policy(cfg_get(cfg, :restart_policy))
    }
  end

  defp cfg_get(cfg, key) when is_atom(key) do
    Map.get(cfg, key) || Map.get(cfg, Atom.to_string(key))
  end

  defp normalize_secrets_mode(mode) when mode in [:none, :ephemeral, :persistent, :managed],
    do: mode

  defp normalize_secrets_mode("managed"), do: :managed
  defp normalize_secrets_mode("persistent"), do: :persistent
  defp normalize_secrets_mode("ephemeral"), do: :ephemeral
  defp normalize_secrets_mode(_), do: :none

  defp reject_memory_snapshot_spawn(%{thaw: name}) when is_binary(name), do: :ok

  defp reject_memory_snapshot_spawn(opts) do
    name = opts[:snapshot] || opts["snapshot"]

    if is_binary(name) and Mjolnir.MemorySnapshot.memory_snapshot?(name) do
      {:error, {:memory_snapshot_requires_thaw, name}}
    else
      :ok
    end
  end

  @doc """
  List all running VMs.
  """
  @spec list() :: [t()]
  def list do
    Registry.select(Mjolnir.VMRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    # Probe every VM concurrently. Serially this was N × up-to-5s, so a single
    # VM whose GenServer mailbox was briefly blocked (e.g. mid-heal on a wedged
    # guest) stalled the whole `GET /api/vms` response (mjolnir-l4i). Bounded
    # concurrency makes the worst case one timeout, not the sum of them.
    |> Task.async_stream(
      fn {vm_id, pid} ->
        try do
          GenServer.call(
            pid,
            :get_state,
            Application.get_env(:mjolnir, :vm_list_probe_timeout_ms, 5000)
          )
        catch
          # A registered-but-unresponsive VM must NOT vanish from the list —
          # omitting it made a live VM look destroyed (mjolnir-l4i). Surface a
          # degraded placeholder so operators see :unreachable, not absence.
          :exit, _ -> unreachable_placeholder(vm_id)
        end
      end,
      max_concurrency: 16,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.map(fn
      {:ok, vm} -> vm
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Build the :unreachable placeholder for a blocked/unresponsive VM. The
  # owner_id is read from the durable StateStore record (not the blocked
  # GenServer), so the API's owner filter still shows the VM to its owner
  # instead of hiding it (mjolnir-l4i).
  defp unreachable_placeholder(vm_id) do
    owner =
      case Mjolnir.StateStore.get(vm_id) do
        {:ok, record} -> Map.get(record.spawn_config || %{}, "owner_id")
        _ -> nil
      end

    %__MODULE__{id: vm_id, state: :unreachable, owner_id: owner}
  end

  @doc """
  List VMs that have a `:running` intent record in StateStore but no live
  GenServer in `Mjolnir.VMRegistry` — i.e. they crashed (hypervisor exit,
  failed boot) and are awaiting the next `Mjolnir.Reconcile` pass.

  Surfacing these turns "the VM inexplicably vanished" into "the VM is
  recovering": the data (rootfs subvolume) and intent are both preserved, and
  the Health.Monitor tick will resume it. `rootfs_present` flags the one case
  needing human attention — a `:running` record whose subvolume is gone.
  """
  @spec list_stranded() :: [Mjolnir.StateStore.Record.t()]
  def list_stranded do
    registered =
      Mjolnir.VMRegistry
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> MapSet.new()

    Mjolnir.StateStore.list_by_intent(:running)
    |> Enum.reject(fn record -> MapSet.member?(registered, record.uuid) end)
  end

  @doc """
  List VMs that `Mjolnir.Reconcile` has retired to `intent: :failed` — records
  whose VM repeatedly failed to resume (or whose rootfs is gone). These are no
  longer auto-resumed; an operator must `revive/1` them (after fixing the
  cause) or dispose of them with `forget/1` (which soft-deletes the rootfs to
  `@trash`). Until then their rootfs subvolume is preserved per the durability
  invariant, so they remain visible and recoverable.
  """
  @spec list_failed() :: [Mjolnir.StateStore.Record.t()]
  def list_failed do
    Mjolnir.StateStore.list_by_intent(:failed)
  end

  @doc """
  List VMs that ended and were **not** restarted — records `Mjolnir.Reconcile`
  finalized because their `restart_policy` is `:never` (mjolnir-yhr).

  Distinct from `:failed`: a failed record is one that could not be resumed and
  an operator may want to fix; a stopped one is working as designed. Both keep
  their rootfs subvolume, which is the point — for an agent workload that
  subvolume is the workspace a later owner-initiated start resumes from.

  Listed separately rather than left invisible: the rootfs is still on disk, and
  storage you cannot see in the API is storage nobody reclaims.
  """
  @spec list_stopped() :: [Mjolnir.StateStore.Record.t()]
  def list_stopped do
    Mjolnir.StateStore.list_by_intent(:stopped)
  end

  @doc """
  Operator action: retire a stranded `:running` record to `:failed` so
  `Mjolnir.Reconcile` stops trying to resume it. Does NOT touch the rootfs
  subvolume — the VM stays fully recoverable via `revive/1`. Refuses if the VM
  has a live GenServer (kill it first) or no record exists.
  """
  @spec retire(vm_id()) :: :ok | {:error, :not_found | :running}
  def retire(vm_id) when is_binary(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{_pid, _}] ->
        {:error, :running}

      [] ->
        case Mjolnir.StateStore.get(vm_id) do
          {:ok, record} ->
            Mjolnir.StateStore.put(%{record | intent: :failed})

          :not_found ->
            {:error, :not_found}
        end
    end
  end

  @doc """
  Operator action: revive a `:failed` record back to `:running` (clearing the
  resume-failure counter) so the next `Mjolnir.Reconcile` pass attempts to boot
  it again. Use after fixing whatever made it fail (host capacity, kernel, etc.).
  """
  @spec revive(vm_id()) :: :ok | {:error, term()}
  def revive(vm_id) when is_binary(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{_pid, _}] ->
        # The VM has a LIVE GenServer, so Mjolnir.Reconcile skips it and a flip
        # of StateStore intent is a no-op. The failure mode here is "process
        # running but guest wedged" (mjolnir-l4i): probe the guest and, if it's
        # unreachable, reboot it in place rather than reporting a false success.
        if guest_reachable?(vm_id) do
          :ok
        else
          Logger.warning(
            "VM #{vm_id} is registered but its guest is unreachable; rebooting to revive"
          )

          case reboot(vm_id) do
            {:ok, %{guest_healthy: true}} -> :ok
            {:ok, %{guest_healthy: false}} -> {:error, :guest_unreachable_after_reboot}
            {:error, reason} -> {:error, reason}
          end
        end

      [] ->
        # No live GenServer: a crashed/retired record. Clear the failure counter
        # and flip intent back to :running so the next Reconcile pass re-resumes.
        case Mjolnir.StateStore.get(vm_id) do
          {:ok, record} ->
            runtime =
              (record.runtime || %{})
              |> Map.drop([
                "resume_failures",
                "first_failure_at",
                "last_failure_at",
                "finalized_at",
                "finalized_reason"
              ])

            # restart_policy: :never bars the automatic path, not the owner —
            # I5 calls an owner-issued Start "resurrection working as designed".
            # Stamp a one-shot token so the next Reconcile pass resumes this VM
            # once instead of finalizing it straight back to :stopped, which
            # would make revive a silent no-op. See Reconcile.revive_authorized?/1.
            runtime =
              if Mjolnir.Reconcile.restart_policy(record) == :never do
                Logger.info(
                  "VM #{vm_id} has restart_policy=never; revive is an explicit " <>
                    "operator start and authorizes exactly one resume."
                )

                Map.put(runtime, "revive_authorized_at", DateTime.to_iso8601(DateTime.utc_now()))
              else
                runtime
              end

            Mjolnir.StateStore.put(%{record | intent: :running, runtime: runtime})

          :not_found ->
            {:error, :not_found}
        end
    end
  end

  @doc """
  Restart a VM by tearing down its hypervisor and resuming from the preserved
  rootfs — the recovery path for a guest wedged while the hypervisor still
  reports it running (e.g. left frozen by a snapshot's pause/resume — mjolnir-l4i).

  Mechanism: kill the cloud-hypervisor process at the OS level. That makes the
  VM GenServer terminate via its `{:hypervisor_exit, _}` path, which *preserves*
  the `@vms` rootfs subvolume while cleaning up the TAP, virtiofsd, and sockets.
  We then `resume/1` from the StateStore record, booting a fresh hypervisor +
  virtiofsd + TAP against the same rootfs. The OS-level kill is deliberate:
  it works even when the VM GenServer mailbox is blocked (a wedged guest can
  leave an `:infinity` exec stuck in the mailbox), where a `GenServer.call`
  based reboot never would.

  CH's in-place `vm.reboot` is intentionally NOT used: it cannot reconnect
  Mjolnir's external virtiofsd vhost-user backend and would destroy the VM.

  Returns `{:ok, %{rebooted: true, guest_healthy: boolean}}`.
  """
  @spec reboot(vm_id()) :: {:ok, map()} | {:error, term()}
  def reboot(vm_id) when is_binary(vm_id) do
    case Mjolnir.StateStore.get(vm_id) do
      {:ok, record} ->
        _ = kill_hypervisor_process(vm_id)

        if wait_until_deregistered(vm_id, 20_000) do
          case resume(record) do
            {:ok, vm} ->
              {:ok, %{rebooted: true, guest_healthy: guest_alive?(vm, 5)}}

            # Reconcile may have resumed it in the gap — treat as success.
            {:error, {:already_started, _pid}} ->
              {:ok, %{rebooted: true, guest_healthy: guest_reachable?(vm_id)}}

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:error, :vm_did_not_stop}
        end

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  Operator action: permanently dispose of a record that has no live VM
  (typically a `:failed` ghost). Soft-deletes the rootfs subvolume to `@trash`
  (recoverable for `:trash_retention_seconds` per the durability invariant,
  never hard-deleted inline) and then removes the StateStore record. Refuses if
  a live GenServer exists — stop it with `stop/1` first. The record is only
  deleted *after* the subvolume is safely trashed, so a trash failure leaves
  everything in place for a retry.
  """
  @spec forget(vm_id()) :: :ok | {:error, :not_found | :running | term()}
  def forget(vm_id) when is_binary(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{_pid, _}] ->
        {:error, :running}

      [] ->
        case Mjolnir.StateStore.get(vm_id) do
          {:ok, _record} ->
            rootfs = Mjolnir.Reconcile.rootfs_path(vm_id)

            case Mjolnir.BTRFS.trash_subvolume(rootfs) do
              {:ok, _trash_path} -> Mjolnir.StateStore.delete(vm_id)
              :ok -> Mjolnir.StateStore.delete(vm_id)
              {:error, reason} -> {:error, reason}
            end

          :not_found ->
            {:error, :not_found}
        end
    end
  end

  @doc """
  Get the serial console socket path for a VM.

  Connect to this with: screen <path>

  ## Examples

      {:ok, path} = Mjolnir.VM.console(vm.id)
      # Then in another terminal: screen /tmp/mjolnir-dev/abc123_serial.sock
  """
  @spec console(vm_id()) :: {:ok, String.t()} | {:error, term()}
  def console(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        state = GenServer.call(pid, :get_state)

        if state.serial_path do
          {:ok, state.serial_path}
        else
          {:error, :no_serial_console}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Get the compact ticket (z32 node ID) for a VM.

  Returns the z32-encoded ticket string (52 chars) that can be used
  to connect to the VM's shell: `mjolnir connect <ticket>`
  """
  @spec get_ticket(vm_id()) :: {:ok, String.t()} | {:error, :not_ready | :not_found}
  def get_ticket(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        state = GenServer.call(pid, :get_state)

        if state.ticket do
          {:ok, state.ticket}
        else
          {:error, :not_ready}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Get connection info: compact ticket + full iroh JSON addr.

  The `iroh_addr` is the full iroh EndpointAddr JSON, useful for debugging
  and for clients that want relay/IP hints for faster connection.
  """
  @spec connection_info(vm_id()) ::
          {:ok, String.t(), String.t()} | {:error, :not_ready | :not_found}
  def connection_info(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        state = GenServer.call(pid, :get_state)

        if state.ticket do
          {:ok, state.ticket, state.iroh_json}
        else
          {:error, :not_ready}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Wait for PTY to be ready, with timeout.

  Actively polls the guest agent for Iroh status via vsock rather than
  relying on cached boot-time values, so this works even if Iroh took
  longer than the initial boot timeout to connect to relay.

  Returns `{:ok, ticket}` when ready, or `{:error, :timeout}`.

  ## Examples

      {:ok, vm} = Mjolnir.VM.spawn(%{enable_iroh: true})
      {:ok, ticket} = Mjolnir.VM.await_pty(vm.id)
  """
  @spec await_pty(vm_id(), timeout()) :: {:ok, String.t()} | {:error, :timeout | :not_found}
  def await_pty(vm_id, timeout \\ 30_000) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        GenServer.call(pid, {:await_pty, timeout}, timeout + 5_000)

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Print instructions for interacting with the VM.

  Serial console is currently disabled. Use `exec/2` for commands,
  or wait for networking support (TAP + SSH) for interactive shells.
  """
  @spec attach(vm_id()) :: :ok | {:error, term()}
  def attach(vm_id) do
    case status(vm_id) do
      :running ->
        IO.puts("""

        VM #{String.slice(vm_id, 0..7)}... is running.

        Interactive serial console is not currently enabled.
        Use VM.exec/2 to run commands:

          Mjolnir.VM.exec("#{vm_id}", "uname -a")
          Mjolnir.VM.exec("#{vm_id}", "ps aux")
          Mjolnir.VM.exec("#{vm_id}", "cat /etc/os-release")

        For interactive SSH access, networking support is needed (TODO).

        """)

        :ok

      other ->
        {:error, other}
    end
  end

  @doc """
  Authorize an Iroh peer for secret injection into a VM.
  The peer's NodeId will be sent to the guest agent, which will allow
  SECRET_INJECT_ALPN connections from that peer.
  """
  @spec authorize_inject_peer(vm_id(), String.t()) :: :ok | {:error, term()}
  def authorize_inject_peer(vm_id, peer_node_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] -> GenServer.call(pid, {:authorize_inject_peer, peer_node_id})
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Deliver a message from one VM to another.

  Routes through the VMRegistry for running VMs, or through the
  DormantRegistry for checkpointed VMs (triggering a restore).
  """
  @spec deliver_message(vm_id(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  @spec deliver_message(vm_id(), String.t(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def deliver_message(target_vm_id, from_vm_id, payload, opts \\ []) do
    cond do
      Registry.lookup(Mjolnir.VMRegistry, target_vm_id) != [] ->
        accept_and_kick(target_vm_id, from_vm_id, payload, opts)

      match?({:ok, _}, Mjolnir.DormantRegistry.lookup(target_vm_id)) ->
        if Mjolnir.Admit.thaw_allowed?(target_vm_id, payload) do
          accept_and_kick(target_vm_id, from_vm_id, payload, opts)
        else
          {:error, :admission_denied}
        end

      true ->
        {:error, :not_found}
    end
  end

  defp accept_and_kick(vm_id, from_vm_id, payload, opts) do
    case Mjolnir.Mailbox.accept(vm_id, from_vm_id, payload, opts) do
      {:ok, result} ->
        Mjolnir.Mailbox.kick(vm_id)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def restore_for_mail(vm_id), do: restore_dormant_vm(vm_id)

  @doc """
  Handle a VM signaling "done" — snapshot and go dormant.

  Called by the vsock connection handler when the guest sends signal_done.
  """
  @spec handle_done(vm_id()) :: :ok | {:error, term()}
  def handle_done(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        GenServer.call(pid, :handle_done, 60_000)

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Open or ensure a terminal session in the VM"
  @spec terminal_open(vm_id(), String.t()) :: {:ok, map()} | {:error, term()}
  def terminal_open(vm_id, session_name) do
    GenServer.call(via_tuple(vm_id), {:terminal_open, session_name})
  end

  @doc "Read terminal content"
  @spec terminal_read(vm_id(), String.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def terminal_read(vm_id, session_name, scrollback_lines \\ 100) do
    GenServer.call(via_tuple(vm_id), {:terminal_read, session_name, scrollback_lines})
  end

  @doc "Send command or keys to terminal"
  @spec terminal_send(vm_id(), String.t(), String.t() | nil, list() | nil) ::
          {:ok, map()} | {:error, term()}
  def terminal_send(vm_id, session_name, command \\ nil, keys \\ nil) do
    GenServer.call(via_tuple(vm_id), {:terminal_send, session_name, command, keys})
  end

  @doc "Send command and wait for output"
  @spec terminal_send_and_read(vm_id(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def terminal_send_and_read(vm_id, session_name, command, timeout_ms \\ 30_000) do
    GenServer.call(
      via_tuple(vm_id),
      {:terminal_send_and_read, session_name, command, timeout_ms},
      timeout_ms + 10_000
    )
  end

  @doc "List terminal sessions"
  @spec terminal_list(vm_id()) :: {:ok, map()} | {:error, term()}
  def terminal_list(vm_id) do
    GenServer.call(via_tuple(vm_id), :terminal_list)
  end

  @doc "Close a terminal session"
  @spec terminal_close(vm_id(), String.t()) :: {:ok, map()} | {:error, term()}
  def terminal_close(vm_id, session_name) do
    GenServer.call(via_tuple(vm_id), {:terminal_close, session_name})
  end

  @doc """
  Live-probe the guest agent's Iroh status via vsock. Used by health checks
  and by the resume-mode identity probe. Returns the same shape as the
  internal await loop: `{:ok, %{ready: bool, node_id: ..., ticket: ...}}`.
  """
  @spec iroh_status(vm_id(), timeout()) :: {:ok, map()} | {:error, any()}
  def iroh_status(vm_id, timeout \\ 3_000) do
    call_vm(vm_id, {:probe_iroh_status, timeout}, timeout + 1_000)
  end

  @doc """
  Re-push `configure_iroh(enable_iroh)` to the guest. Idempotent; used by
  `Mjolnir.Health.IrohConnection.heal/1`.
  """
  @spec reconfigure_iroh(vm_id()) :: :ok | {:error, any()}
  def reconfigure_iroh(vm_id) do
    call_vm(vm_id, :reconfigure_iroh, 10_000)
  end

  @doc """
  Re-push `configure_network(guest_ip)` to the guest. Idempotent; used by
  `Mjolnir.Health.GuestNetwork.heal/1`.
  """
  @spec reconfigure_network(vm_id()) :: :ok | {:error, any()}
  def reconfigure_network(vm_id) do
    call_vm(vm_id, :reconfigure_network, 10_000)
  end

  @doc """
  Tear down the current `Mjolnir.Vsock.Connection` GenServer and start a
  fresh one. Used by `Mjolnir.Health.VsockConnection.heal/1` when the
  connection has rotted.
  """
  @spec rebuild_vsock_connection(vm_id()) :: :ok | {:error, any()}
  def rebuild_vsock_connection(vm_id) do
    call_vm(vm_id, :rebuild_vsock_connection, 15_000)
  end

  defp call_vm(vm_id, msg, timeout) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, msg, timeout)
        catch
          :exit, reason -> {:error, {:exit, reason}}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Spawn a VM with a pre-assigned ID (used for restoring dormant VMs).

  Like `spawn/1` but uses the given `:id` from opts instead of generating a new UUID.
  """
  @spec spawn_with_id(spawn_opts()) :: {:ok, t()} | {:error, term()}
  def spawn_with_id(opts) do
    vm_id = opts[:id] || raise ArgumentError, ":id is required for spawn_with_id"

    with :ok <- reject_memory_snapshot_spawn(opts) do
      do_spawn(Map.put(opts, :id, vm_id))
    end
  end

  @doc """
  Resume a VM from a persisted StateStore record. Used by `Mjolnir.Reconcile`
  at boot. Skips rootfs clone (uses existing `@vms/<uuid>` subvolume) and
  skips guest-agent injection. Network/identity/iroh are re-pushed
  idempotently to recover from any guest drift.
  """
  @spec resume(Mjolnir.StateStore.Record.t()) :: {:ok, t()} | {:error, term()}
  def resume(%Mjolnir.StateStore.Record{uuid: uuid, spawn_config: cfg}) do
    opts = %{
      id: uuid,
      resume: true,
      base_image: Map.get(cfg, "base_image"),
      vcpus: Map.get(cfg, "vcpus"),
      memory_mb: Map.get(cfg, "memory_mb"),
      enable_iroh: Map.get(cfg, "enable_iroh"),
      owner_id: Map.get(cfg, "owner_id"),
      ssh_public_key: Map.get(cfg, "ssh_public_key"),
      secrets_mode:
        case Map.get(cfg, "secrets_mode") do
          "managed" -> :managed
          "persistent" -> :persistent
          "ephemeral" -> :ephemeral
          _ -> :none
        end,
      # Carried across the resume so a VM that survives one rehydration doesn't
      # quietly lose its lifetime policy and become revivable on the next one.
      # (Reconcile refuses to resume a :never record at all, so this is belt to
      # that braces — it also covers Mjolnir.VM.revive/1, which goes through
      # resume/1 by an operator's explicit choice.)
      restart_policy: normalize_restart_policy(Map.get(cfg, "restart_policy"))
    }

    case DynamicSupervisor.start_child(
           Mjolnir.VMSupervisor,
           {__MODULE__, opts}
         ) do
      {:ok, pid} ->
        # Resume keeps its historical 60s floor (an existing subvolume + guest
        # drift re-push is heavier than a fresh boot); managed re-open of the
        # snapshot-carried LUKS volume can still push past it, so take the max.
        resume_timeout = max(60_000, await_boot_timeout(opts))

        case GenServer.call(pid, :await_boot, resume_timeout) do
          {:ok, vm} -> {:ok, vm}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts.id))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts.id},
      start: {__MODULE__, :start_link, [opts]},
      # :temporary, not :transient. A transient restart re-runs init with the
      # ORIGINAL (resume:false) opts, which always fails at clone because the
      # subvolume still exists — a wasted restart that never recovers anything.
      # Recovery is owned by Mjolnir.Reconcile (Health.Monitor tick), which
      # resumes from the preserved subvolume + :running record. See mjolnir-mpi.
      restart: :temporary
    }
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with :ok <- store_identity(opts),
         :ok <- store_git_signing(opts) do
      init_state(opts)
    else
      {:error, reason} ->
        Logger.error("VM #{opts.id} refused spawn: opaque store failed (#{inspect(reason)})")

        {:stop, :normal}
    end
  end

  defp store_identity(opts) do
    case opts[:identity] do
      nil -> :ok
      identity -> Mjolnir.Identity.put(opts.id, identity)
    end
  end

  # New vm_id mints a new key. Never copy `_opaque` from another id.
  defp store_git_signing(opts) do
    case opts[:git_signing] do
      nil ->
        :ok

      false ->
        :ok

      true ->
        case Mjolnir.GitSigning.mint(opts.id) do
          {:ok, _pub} -> :ok
          {:error, reason} -> {:error, reason}
        end

      %{copy_from: _} ->
        {:error, :cannot_copy_git_signing}

      %{from_vm_id: _} ->
        {:error, :cannot_copy_git_signing}
    end
  end

  defp init_state(opts) do
    # Resolve SSH public key: spawn opts > app config > nil
    ssh_key = opts[:ssh_public_key] || Application.get_env(:mjolnir, :default_ssh_public_key)

    # Resolve enable_iroh: spawn opts > app config > true
    enable_iroh =
      case opts[:enable_iroh] do
        nil -> Application.get_env(:mjolnir, :enable_iroh, true)
        val -> val
      end

    # Resolve hypervisor: spawn opts > app config > default
    hypervisor = opts[:hypervisor] || Mjolnir.Hypervisor.impl()

    state = %__MODULE__{
      id: opts.id,
      state: :booting,
      config: build_config(opts),
      hypervisor: hypervisor,
      ssh_public_key: ssh_key,
      enable_iroh: enable_iroh,
      owner_id: opts[:owner_id],
      # secrets_mode flows from spawn opts (router/resume already mapped it to an
      # atom). Without this it defaulted to :none, silently disabling
      # :persistent/:managed for every API-spawned VM.
      secrets_mode: opts[:secrets_mode] || :none,
      # Optional secret material to write into the volume on first inject
      # (:managed only). Held transiently in host memory; never persisted to
      # StateStore/restore_config — the content lives encrypted in the LUKS volume.
      secrets_payload: opts[:secrets],
      resume_mode: opts[:resume] || false,
      metadata: Mjolnir.StateStore.Record.normalize_metadata(opts[:metadata] || %{}),
      # Anything other than an explicit :never is :always. A malformed policy
      # must not silently become "never restart" — that would strand VMs on a
      # typo, and the failure would only show up much later, during a recovery.
      # The string form is accepted too: the dormant-restore path round-trips
      # its config through JSON, so a policy that only matched the atom would be
      # silently downgraded to :always on the way back.
      restart_policy: normalize_restart_policy(opts[:restart_policy]),
      thaw_name: opts[:thaw]
    }

    continue = if is_binary(opts[:thaw]), do: :thaw, else: :boot
    {:ok, state, {:continue, continue}}
  end

  @impl true
  def handle_continue(:thaw, state) do
    case do_thaw(state) do
      {:ok, new_state} ->
        start_secrets_unlock(new_state)

      {:error, reason} ->
        Logger.error("VM #{state.id} failed to thaw: #{inspect(reason)}")

        if state.boot_waiter do
          GenServer.reply(state.boot_waiter, {:error, reason})
        end

        {:stop, :normal, %{state | state: :failed}}
    end
  end

  def handle_continue(:boot, state) do
    case do_boot(state) do
      {:ok, new_state} ->
        # Boot is NOT necessarily over here. For a :managed VM the LUKS unlock
        # still has to happen, and it must happen before the VM calls itself
        # :running — but it must NOT happen on this process, or the mailbox
        # stays shut for its whole 60s bound (mjolnir-y32).
        start_secrets_unlock(new_state)

      {:error, reason} ->
        Logger.error("VM #{state.id} failed to boot: #{inspect(reason)}")
        # Return :normal so the :transient DynamicSupervisor does NOT restart
        # (transient processes only restart on abnormal termination)
        {:stop, :normal, %{state | state: :failed}}
    end
  end

  @impl true
  def handle_call(:await_boot, _from, %{state: :running} = state) do
    {:reply, {:ok, state}, state}
  end

  def handle_call(:await_boot, from, %{state: :booting} = state) do
    # Store the caller to reply later when boot completes
    {:noreply, Map.put(state, :boot_waiter, from)}
  end

  def handle_call(:status, _from, state) do
    {:reply, state.state, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  # Persistent secrets and restart_policy: :never cannot go dormant
  # (add-buzz-local-client: :never must not enter DormantRegistry).
  def handle_call(:handle_done, _from, state) do
    case Mjolnir.Admit.dormancy_reason(state) do
      {:error, reason} ->
        Logger.warning(
          "VM #{state.id} refusing dormancy (#{reason}). " <>
            "Stop explicitly with VM.stop/1 or snapshot manually with VM.snapshot/2."
        )

        {:reply, {:error, reason}, state}

      :ok ->
        do_handle_done(state)
    end
  end

  defp do_handle_done(state) do
    snapshot_name = "dormant-#{state.id}-#{System.os_time(:second)}"

    case do_snapshot(state, snapshot_name, []) do
      {:ok, _metadata} ->
        original_config = restore_config(state)
        Mjolnir.DormantRegistry.register(state.id, snapshot_name, original_config, state.owner_id)
        # DormantRegistry now owns this VM's persisted state; remove the
        # running-intent record so Mjolnir.Reconcile doesn't try to resume it.
        _ = Mjolnir.StateStore.delete(state.id)
        Mjolnir.EventBus.publish(state.id, :vm_dormant, %{snapshot: snapshot_name})
        {:stop, :normal, :ok, state}

      {:error, reason} ->
        Logger.error("Failed to snapshot VM #{state.id} for done: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  # Runs the vsock round-trip OFF the GenServer (mjolnir-8ie).
  #
  # Handling exec inline blocks this process's mailbox for the whole duration of
  # the command. With the old `:infinity` inner timeout that was forever: a guest
  # whose agent stopped answering (which a long CH pause reliably causes) left
  # the VM permanently unreachable — every later `status`, health probe, and stop
  # timed out, and no heal path could help because they all route through here.
  #
  # The caller still blocks exactly as before; the difference is that everyone
  # else keeps being served. Nothing here mutates state, so there is no
  # serialization to preserve, and Connection multiplexes concurrent requests by
  # id already.
  def handle_call({:exec, command, timeout}, from, state) do
    case state.vsock_conn do
      nil ->
        {:reply, {:error, :no_vsock_connection}, state}

      conn ->
        # spawn_monitor, not Task.start: the monitor ref is how we learn the exec
        # finished (or died), which is what keeps exec_inflight honest. Unlinked
        # either way, so a failure here cannot take the VM down. Note this module
        # defines its own spawn/1 (the VM lifecycle API), hence the qualified call.
        {_pid, ref} =
          :erlang.spawn_monitor(fn ->
            result =
              try do
                Mjolnir.Vsock.Connection.exec(conn, command, timeout)
              catch
                # The Connection died mid-request (or was never alive). Reply with
                # an error rather than letting the caller hang to its own timeout.
                :exit, reason -> {:error, {:vsock_unavailable, reason}}
              end

            GenServer.reply(from, result)
          end)

        {:noreply, %{state | exec_inflight: Map.put(state.exec_inflight, ref, command)}}
    end
  end

  # Back-compat for any in-flight 2-tuple exec call.
  def handle_call({:exec, command}, from, state) do
    handle_call({:exec, command, @default_exec_timeout}, from, state)
  end

  # Fires a one-shot vsock request authorizing a secret-injection peer. This
  # mutates guest-side auth config over the wire, but nothing in this clause
  # touches the VM GenServer's own `state`, so it is safe to move off-process
  # exactly like the read-only round trips (mjolnir-75d).
  def handle_call({:authorize_inject_peer, peer_node_id}, from, state) do
    conn = state.vsock_conn

    reply_off_process(from, fn ->
      if conn do
        request = Mjolnir.Vsock.Protocol.configure_secrets_auth_request([peer_node_id])

        case Mjolnir.Vsock.Connection.send_request(conn, request) do
          {:ok, _stdout} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, :no_vsock_connection}
      end
    end)

    {:noreply, state}
  end

  def handle_call({:terminal_open, session_name}, from, state) do
    conn = state.vsock_conn

    reply_off_process(from, fn ->
      if conn,
        do: Mjolnir.Vsock.Connection.terminal_open(conn, session_name),
        else: {:error, :no_vsock_connection}
    end)

    {:noreply, state}
  end

  def handle_call({:terminal_read, session_name, scrollback_lines}, from, state) do
    conn = state.vsock_conn

    reply_off_process(from, fn ->
      if conn,
        do: Mjolnir.Vsock.Connection.terminal_read(conn, session_name, scrollback_lines),
        else: {:error, :no_vsock_connection}
    end)

    {:noreply, state}
  end

  def handle_call({:terminal_send, session_name, command, keys}, from, state) do
    conn = state.vsock_conn

    reply_off_process(from, fn ->
      if conn,
        do: Mjolnir.Vsock.Connection.terminal_send(conn, session_name, command, keys),
        else: {:error, :no_vsock_connection}
    end)

    {:noreply, state}
  end

  # IMPORTANT: terminal_send_and_read is handled asynchronously to avoid blocking
  # the VM GenServer for up to 30+ seconds. Other terminal/exec calls can proceed
  # concurrently while this long-running operation is in flight.
  def handle_call({:terminal_send_and_read, session_name, command, timeout_ms}, from, state) do
    if state.vsock_conn do
      conn = state.vsock_conn

      Task.Supervisor.start_child(Mjolnir.TaskSupervisor, fn ->
        try do
          result =
            Mjolnir.Vsock.Connection.terminal_send_and_read(
              conn,
              session_name,
              command,
              timeout_ms
            )

          GenServer.reply(from, result)
        catch
          kind, reason ->
            GenServer.reply(from, {:error, {kind, reason}})
        end
      end)

      {:noreply, state}
    else
      {:reply, {:error, :no_vsock_connection}, state}
    end
  end

  def handle_call(:terminal_list, from, state) do
    conn = state.vsock_conn

    reply_off_process(from, fn ->
      if conn,
        do: Mjolnir.Vsock.Connection.terminal_list(conn),
        else: {:error, :no_vsock_connection}
    end)

    {:noreply, state}
  end

  def handle_call({:terminal_close, session_name}, from, state) do
    conn = state.vsock_conn

    reply_off_process(from, fn ->
      if conn,
        do: Mjolnir.Vsock.Connection.terminal_close(conn, session_name),
        else: {:error, :no_vsock_connection}
    end)

    {:noreply, state}
  end

  def handle_call({:snapshot, name, opts}, _from, state) do
    case do_snapshot(state, name, opts) do
      {:ok, metadata} -> verify_after_snapshot(state, name, metadata, opts)
      {:error, _reason} = err -> {:reply, err, state}
    end
  end

  def handle_call({:freeze, _name, _opts}, _from, %{state: state_name} = state)
      when state_name != :running do
    {:reply, {:error, {:not_running, state_name}}, state}
  end

  def handle_call({:freeze, name, opts}, _from, state) do
    vm = %{
      id: state.id,
      socket_path: state.socket_path,
      vsock_path: state.vsock_path,
      secrets_mode: state.secrets_mode
    }

    freeze_opts =
      opts
      |> Keyword.put(:owner_id, opts[:owner_id] || state.owner_id)
      |> Keyword.put(:secrets_mode, state.secrets_mode)

    case Mjolnir.MemorySnapshot.freeze(vm, name, freeze_opts) do
      {:ok, metadata} ->
        _ = stamp_freeze_metadata(name, state, metadata)
        # Same as handle_done: drop running intent so Reconcile does not
        # cold-boot the live subvolume after we tear the VMM down.
        _ = Mjolnir.StateStore.delete(state.id)
        Mjolnir.EventBus.publish(state.id, :vm_frozen, %{snapshot: name})
        {:stop, :normal, {:ok, Mjolnir.MemorySnapshot.annotate(metadata)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Runs OFF the GenServer (mjolnir-75d). `timeout` bounds how long the caller
  # waits, not the mailbox — this used to run inline and additionally
  # DISCARDED `timeout` (`_ = timeout`), silently falling back to
  # vsock_request's 10s default, so Health.IrohConnection's careful
  # `iroh_status(vm.id, 3_000)` blocked every other caller for up to 10s
  # against a severed vsock. Fixed as part of moving this off-process: nothing
  # here touches `state`, so it is a read-only round trip like `terminal_*`.
  def handle_call({:probe_iroh_status, timeout}, from, state) do
    vsock_path = state.vsock_path

    reply_off_process(from, fn ->
      if vsock_path,
        do: query_iroh_status(vsock_path, timeout),
        else: {:error, :no_vsock_path}
    end)

    {:noreply, state}
  end

  # The bug report grouped `:reconfigure_iroh` with the state-mutating Tier 2
  # calls, but it does not actually touch `state` — `configure_iroh/2` only
  # reads `vsock_path`/`enable_iroh` and pushes a request over the wire. It is
  # safe to move off-process the same way as the read-only round trips above.
  def handle_call(:reconfigure_iroh, from, state) do
    vsock_path = state.vsock_path
    enable_iroh = state.enable_iroh

    reply_off_process(from, fn ->
      if vsock_path,
        do: configure_iroh(vsock_path, enable_iroh),
        else: {:error, :no_vsock_path}
    end)

    {:noreply, state}
  end

  # Same situation as `:reconfigure_iroh` above: host-side TAP repair and the
  # guest-side vsock push both read from `state` but never write it, so this
  # is safe to move off-process too, despite being grouped with the Tier 2
  # mutators in the bug report.
  def handle_call(:reconfigure_network, from, state) do
    # Two-sided repair: host-side (TAP link, proxy_arp, /32 route) then
    # guest-side (addr + default route via vsock). Each is idempotent;
    # order matters because guest-side config is irrelevant while the host
    # TAP is admin-down. The L2 probe pings 1.1.1.1 from inside the guest,
    # which exercises both sides in one shot.
    vsock_path = state.vsock_path
    net_config = state.net_config

    reply_off_process(from, fn ->
      cond do
        vsock_path == nil ->
          {:error, :no_vsock_path}

        net_config == nil ->
          {:error, :no_net_config}

        true ->
          with :ok <- Mjolnir.Network.repair_tap(net_config),
               :ok <- configure_guest_network(vsock_path, net_config.guest_ip) do
            :ok
          end
      end
    end)

    {:noreply, state}
  end

  # UNLIKE the clauses above, this one genuinely mutates `state` (vsock_conn
  # is replaced), so it cannot just spawn-and-reply from the worker process —
  # doing that from outside this GenServer would either race writing `state`
  # from the wrong process or silently drop the new connection pid. Instead:
  # stop the old connection and start the new one off-process (both are
  # bounded I/O), then report back via `handle_info({:vsock_rebuild_result,
  # _}, ...)` so the state update AND the reply happen from this process.
  # `vsock_rebuild_waiters` piggybacks any caller that arrives while a rebuild
  # is already in flight, instead of racing a second rebuild.
  def handle_call(:rebuild_vsock_connection, from, %{vsock_rebuild_waiters: waiters} = state)
      when waiters != [] do
    {:noreply, %{state | vsock_rebuild_waiters: [from | waiters]}}
  end

  def handle_call(:rebuild_vsock_connection, from, state) do
    old_conn = state.vsock_conn
    vsock_path = state.vsock_path
    vm_id = state.id
    owner = self()

    {_pid, ref} =
      :erlang.spawn_monitor(fn ->
        result =
          try do
            do_rebuild_vsock_connection(vm_id, old_conn, vsock_path)
          catch
            kind, reason -> {:error, {:vsock_unavailable, {kind, reason}}}
          end

        send(owner, {:vsock_rebuild_result, result})
      end)

    {:noreply, %{state | vsock_rebuild_waiters: [from], vsock_rebuild_ref: ref}}
  end

  def handle_call({:await_pty, timeout}, _from, state) do
    # If iroh is disabled, PTY is available over vsock immediately
    unless state.enable_iroh do
      {:reply, {:ok, state.id}, %{state | pty_ready: true}}
    else
      # If we already have a ticket cached, return it immediately
      if state.ticket do
        {:reply, {:ok, state.ticket}, state}
      else
        # Poll the guest agent for live Iroh status via vsock
        case await_iroh_ready(state.vsock_path, timeout) do
          %{ticket: ticket} = info ->
            z32 = Mjolnir.Ticket.from_hex(info[:node_id])

            updated = %{
              state
              | iroh_node_id: info[:node_id],
                iroh_json: ticket,
                ticket: z32,
                pty_ready: true
            }

            {:reply, {:ok, z32}, updated}

          nil ->
            {:reply, {:error, :timeout}, state}
        end
      end
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{hypervisor_pid: pid} = state) do
    Logger.warning("Hypervisor process exited: #{inspect(reason)}")
    {:stop, {:hypervisor_exit, reason}, %{state | state: :stopped}}
  end

  def handle_info({port, {:data, data}}, %{hypervisor_port: port} = state) do
    Logger.debug("Hypervisor output: #{data}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{hypervisor_port: port} = state) do
    Logger.info("Hypervisor exited with status: #{status}")
    {:stop, {:hypervisor_exit, status}, %{state | state: :stopped}}
  end

  def handle_info({port, {:data, data}}, %{virtiofsd_port: port} = state) when is_port(port) do
    Logger.debug("virtiofsd output: #{data}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{virtiofsd_port: port} = state)
      when is_port(port) do
    Logger.warning("virtiofsd exited with status #{status} for VM #{state.id}")
    {:noreply, %{state | virtiofsd_port: nil}}
  end

  def handle_info({port, {:data, data}}, state) when is_port(port) do
    extra_ports = state.extra_virtiofsd_ports || []

    case Enum.find(extra_ports, fn {_tag, p, _sock} -> p == port end) do
      {tag, _port, _sock} ->
        Logger.debug("virtiofsd[#{tag}] output: #{data}")
        {:noreply, state}

      nil ->
        Logger.debug("Unknown port data: #{inspect(data)}")
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    extra_ports = state.extra_virtiofsd_ports || []

    case Enum.find(extra_ports, fn {_tag, p, _sock} -> p == port end) do
      {tag, _port, sock} ->
        Logger.warning("virtiofsd[#{tag}] exited with status #{status} for VM #{state.id}")

        updated = Enum.reject(extra_ports, fn {_t, p, _s} -> p == port end)
        # Clean up the socket
        Mjolnir.VirtioFS.cleanup(sock)
        {:noreply, %{state | extra_virtiofsd_ports: updated}}

      nil ->
        {:noreply, state}
    end
  end

  # An exec Task finished (or crashed). Either way it is no longer in flight, so
  # the VM stops being "busy" and Health may judge it normally again.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{exec_inflight: inflight} = state)
      when is_map_key(inflight, ref) do
    {:noreply, %{state | exec_inflight: Map.delete(inflight, ref)}}
  end

  # The rebuild spawned by `handle_call(:rebuild_vsock_connection, ...)`
  # reported back. This is the ONLY place `vsock_conn` gets written as a
  # result of a rebuild — folding it in here (rather than in the spawned
  # worker) guarantees the mutation happens from this GenServer's own process.
  # Replies to every caller that piggybacked while the rebuild was in flight.
  def handle_info({:vsock_rebuild_result, result}, %{vsock_rebuild_waiters: waiters} = state) do
    state =
      case result do
        {:ok, conn} ->
          %{state | vsock_conn: conn}

        {:error, reason} ->
          Logger.error("Rebuild vsock conn failed for #{state.id}: #{inspect(reason)}")
          %{state | vsock_conn: nil}
      end

    outcome = if match?({:ok, _}, result), do: :ok, else: result

    Enum.each(waiters, &GenServer.reply(&1, outcome))

    {:noreply, %{state | vsock_rebuild_waiters: [], vsock_rebuild_ref: nil}}
  end

  # The rebuild worker died without reporting. try/catch inside it converts
  # ordinary failures into an {:error, _} result, so reaching here means it was
  # killed uncatchably (Process.exit/2 :kill) or the node is coming apart.
  # Fail the waiters rather than leaving them queued forever: a permanently
  # non-empty waiter list makes every subsequent rebuild piggyback onto a queue
  # that can never drain, wedging exactly the recovery path this exists to keep
  # working. Arrives after the normal result message in the healthy case, where
  # the ref is already nil and this clause does not match.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{vsock_rebuild_ref: ref, vsock_rebuild_waiters: waiters} = state
      )
      when is_reference(ref) do
    Logger.error(
      "VM #{state.id}: vsock rebuild worker died before reporting (#{inspect(reason)}); " <>
        "failing #{length(waiters)} waiting caller(s)"
    )

    Enum.each(waiters, &GenServer.reply(&1, {:error, {:rebuild_worker_died, reason}}))

    {:noreply, %{state | vsock_rebuild_waiters: [], vsock_rebuild_ref: nil}}
  end

  # --- managed-secrets unlock, off-process (mjolnir-y32) ---------------------
  #
  # Three ways the unlock ends, and all three must land on finish_boot/2 — a VM
  # left in :booting forever is worse than one that boots with a recorded
  # failure, because nothing else in the system retries or reaps that state.

  def handle_info(
        {:secrets_unlock_result, pid, result},
        %{secrets_unlock_pid: pid} = state
      )
      when is_pid(pid) do
    Process.demonitor(state.secrets_unlock_ref, [:flush])
    finish_boot(state, unlock_failure(state.id, result))
  end

  # The unlock worker died without reporting. Its own try/catch turns ordinary
  # failures into {:error, _}, so arriving here means it was killed uncatchably
  # — including by our own watchdog below.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{secrets_unlock_ref: ref} = state
      )
      when is_reference(ref) do
    finish_boot(state, unlock_failure(state.id, {:error, {:unlock_worker_died, reason}}))
  end

  # Watchdog. vsock_request/3 already carries its own bound, so this only fires
  # if the worker is stuck somewhere that bound does not cover (a blocked
  # connect, an escrow read on a wedged filesystem). Without it, such a worker
  # would pin the VM in :booting indefinitely and strand the await_boot caller.
  def handle_info({:secrets_unlock_timeout, ref}, %{secrets_unlock_ref: ref} = state)
      when is_reference(ref) do
    if is_pid(state.secrets_unlock_pid), do: Process.exit(state.secrets_unlock_pid, :kill)
    # The :DOWN that kill produces arrives next and calls finish_boot/2 — do not
    # finish here as well, or the VM transitions twice.
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("VM #{state.id} received: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:deliver_mailbox, %{state: :running, vsock_conn: conn} = state)
      when not is_nil(conn) do
    for rec <- Mjolnir.Mailbox.list_unacked(state.id) do
      Mjolnir.Vsock.Connection.deliver_message(
        conn,
        rec["from_vm_id"],
        rec["payload"],
        rec["message_id"]
      )

      _ = Mjolnir.Mailbox.record_attempt(state.id, rec["message_id"])
    end

    {:noreply, state}
  end

  def handle_cast(:deliver_mailbox, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    Logger.warning(
      "[vm-terminate] #{state.id} start reason=#{inspect(reason)} state=#{state.state}"
    )

    # Durability: preserve rootfs and StateStore record unless we're sure the
    # VM should be gone forever. "Sure" = the VM was successfully running AND
    # this exit is :normal (user-initiated VM.stop or handle_done dormant
    # transition). Every other path — supervisor :shutdown, hypervisor crash,
    # boot failure mid-resume — preserves so Mjolnir.Reconcile can retry.
    preserve = preserve_rootfs?(reason, state)

    Logger.warning("[vm-terminate] #{state.id} preserve=#{preserve} → calling cleanup")

    # On a non-preserving teardown (user kill), soft-delete the rootfs with a
    # metadata sidecar BEFORE the StateStore record is deleted, so
    # `mj trash restore` can bring the VM back with enough state for Reconcile
    # to resume it. Nilling rootfs_path makes the subsequent cleanup skip the
    # subvolume (we've already trashed it) while still tearing down the rest.
    state =
      if not preserve and state.rootfs_path do
        meta = trash_metadata_for(state)
        _ = Mjolnir.BTRFS.trash_subvolume(state.rootfs_path, metadata: meta)
        %{state | rootfs_path: nil}
      else
        state
      end

    if state.hypervisor_port || state.net_config || state.rootfs_path do
      cleanup(state, preserve_rootfs: preserve)
    end

    Logger.warning("[vm-terminate] #{state.id} cleanup returned")

    # secrets_mode: :managed — drop the escrowed passphrase ONLY on a real
    # teardown. Keep it when the rootfs is preserved (Reconcile may resume) or
    # when the VM went dormant (registered in DormantRegistry — wake must be able
    # to re-open the snapshot's LUKS volume). A user kill is the one path that
    # both doesn't preserve and isn't dormant.
    if state.secrets_mode == :managed and not preserve do
      case Mjolnir.DormantRegistry.lookup(state.id) do
        {:ok, _entry} ->
          :ok

        :not_found ->
          _ = Mjolnir.SecretEscrow.delete(state.id)
      end
    end

    # Drop the stored nsec on a real teardown (same preserve/dormant rules as
    # escrow). Resume and wake must still be able to re-inject from SecretStore.
    if not preserve do
      case Mjolnir.DormantRegistry.lookup(state.id) do
        {:ok, _entry} ->
          :ok

        :not_found ->
          _ = Mjolnir.Identity.delete(state.id)
          # Forgejo write-key delete → revoke_device → opaque. A failed
          # Forgejo delete stops the chain (opaque stays). No host token
          # is :not_wired (dev/test reconcile find), not a fake delete.
          _ = Mjolnir.GitSigning.revoke(state.id)
      end
    end

    unless preserve do
      _ = Mjolnir.StateStore.delete(state.id)

      case Mjolnir.DormantRegistry.lookup(state.id) do
        {:ok, _} ->
          Mjolnir.Mailbox.kick(state.id)

        :not_found ->
          _ = Mjolnir.Mailbox.drop_mailbox(state.id)
      end
    end

    Logger.warning("[vm-terminate] #{state.id} done")
    :ok
  end

  defp preserve_rootfs?(:normal, %{state: :running}), do: false
  defp preserve_rootfs?(_reason, _state), do: true

  # Serialize the VM's :running record as a plain map for the trash sidecar so
  # `Mjolnir.Storage.restore_from_trash/1` can re-persist intent on restore.
  #
  # Only attach resumable metadata when a StateStore record still exists. The
  # dormant transition (handle_done) deletes the record BEFORE stopping, so its
  # trashed rootfs gets no sidecar — its real state lives in the dormant
  # snapshot and must not be auto-resumed from trash. Best-effort: nil on any
  # error (rootfs is still recoverable, just not auto-resumable).
  defp trash_metadata_for(state) do
    case Mjolnir.StateStore.get(state.id) do
      {:ok, _record} ->
        state
        |> build_running_record()
        |> Mjolnir.StateStore.Record.to_json()
        |> Jason.decode!()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp via_tuple(vm_id) do
    {:via, Registry, {Mjolnir.VMRegistry, vm_id}}
  end

  # Fail-open to :always. See the comment at the call site in init/1: an
  # unrecognised policy becoming :never would strand VMs silently.
  defp normalize_restart_policy(:never), do: :never
  defp normalize_restart_policy("never"), do: :never
  defp normalize_restart_policy(_), do: :always

  defp build_config(opts) do
    %{
      vm_id: opts.id,
      kernel_path: Application.get_env(:mjolnir, :ch_kernel_path),
      # Set during boot
      rootfs_path: "",
      base_image: opts[:base_image] || Application.get_env(:mjolnir, :default_base_image),
      vcpu_count: opts[:vcpus] || Application.get_env(:mjolnir, :default_vcpus),
      mem_size_mib: opts[:memory_mb] || Application.get_env(:mjolnir, :default_memory_mb),
      vsock_cid: Mjolnir.Vsock.cid(opts.id),
      snapshot: opts[:snapshot],
      preserve_iroh_key: opts[:preserve_iroh_key] || false,
      resume: opts[:resume] || false,
      # extra_mounts MUST be threaded into config: do_boot reads it via
      # Map.get(state.config, :extra_mounts, []) to start the extra virtiofsd
      # shares. Before this it was never copied from spawn opts, so any
      # :extra_mounts passed to spawn/1 was silently dropped (gge.1.9).
      extra_mounts: opts[:extra_mounts] || []
    }
  end

  defp do_boot(state) do
    socket_dir = Application.get_env(:mjolnir, :socket_dir)
    base_image = state.config.base_image
    hypervisor = state.hypervisor

    socket_path = Path.join(socket_dir, "#{state.id}.sock")
    vsock_path = hypervisor.vsock_path(socket_dir, state.id)
    serial_path = Path.join(socket_dir, "#{state.id}_serial.sock")

    # Remove stale sockets if they exist (ignore if missing)
    _ = File.rm(socket_path)
    _ = File.rm(vsock_path)
    _ = File.rm(serial_path)

    # Use Process dictionary to track partially-created resources for cleanup
    Process.put(:boot_partial, %{})

    result =
      with :ok <- File.mkdir_p(socket_dir),
           {:ok, rootfs_path} <- clone_rootfs(state.id, base_image, state.config),
           _ = track_rootfs_for_cleanup(state, rootfs_path),
           _ = maybe_inject_guest_agent(state, rootfs_path),
           virtiofsd_socket = Mjolnir.VirtioFS.socket_path(socket_dir, state.id),
           {:ok, virtiofsd_port} <- Mjolnir.VirtioFS.start(rootfs_path, virtiofsd_socket),
           _ = boot_partial_put(:virtiofsd_port, virtiofsd_port),
           extra_mounts = Map.get(state.config, :extra_mounts, []),
           {:ok, extra_virtiofsd_ports} <-
             Mjolnir.VirtioFS.start_many(socket_dir, state.id, extra_mounts),
           _ = boot_partial_put(:extra_virtiofsd_ports, extra_virtiofsd_ports),
           {:ok, net_config} <- Mjolnir.Network.create_tap(state.id),
           _ = boot_partial_put(:net_config, net_config),
           {:ok, hv_port} <- start_hypervisor(hypervisor, state.id, socket_path, serial_path),
           _ = boot_partial_put(:hv_port, hv_port),
           :ok <- wait_for_socket(socket_path),
           config <-
             Map.merge(state.config, %{
               rootfs_path: rootfs_path,
               network_interface: net_config,
               virtiofsd_socket: virtiofsd_socket,
               extra_fs:
                 Enum.map(extra_virtiofsd_ports, fn {tag, _port, sock} ->
                   %{tag: tag, socket: sock}
                 end)
             }),
           :ok <- configure_vm(hypervisor, socket_path, config),
           :ok <- hypervisor.start_instance(socket_path),
           :ok <- wait_for_boot(vsock_path, state),
           # In resume mode, probe what's already configured in the guest so we
           # can skip idempotent re-pushes that would otherwise restart iroh,
           # rewrite hostname, etc. Fresh spawns get an empty probe ⇒ always push.
           probe = probe_resume_state_safe(state, vsock_path),
           :ok <-
             maybe_configure_network(
               state,
               probe,
               vsock_path,
               net_config.guest_ip
             ) do
        # Inject SSH public key if provided — skip in resume mode if the guest's
        # authorized_keys already matches what we'd push.
        if state.ssh_public_key do
          case maybe_configure_ssh(state, probe, vsock_path, state.ssh_public_key) do
            :ok -> Logger.info("SSH keys ok for VM #{state.id}")
            :skipped -> Logger.info("SSH keys match, skipped for VM #{state.id}")
            {:error, reason} -> Logger.warning("SSH key injection failed: #{inspect(reason)}")
          end
        end

        # Inject VM identity (vm_id + API URL for in-VM snapshot trigger)
        api_port = Application.get_env(:mjolnir, :api_port, 4000)
        host_ip = Application.get_env(:mjolnir, :host_api_ip, "10.200.0.1")
        api_url = "http://#{host_ip}:#{api_port}"
        blob_door_url = "http://#{host_ip}:7222"

        case maybe_configure_identity(state, probe, vsock_path, state.id, api_url, blob_door_url) do
          :ok -> Logger.info("VM identity ok for VM #{state.id}")
          :skipped -> Logger.info("VM identity present, skipped for VM #{state.id}")
          {:error, reason} -> Logger.warning("VM identity injection failed: #{inspect(reason)}")
        end

        # Buzz nsec: re-inject every boot (buzz.env is tmpfs). Never log values.
        case maybe_inject_agent_identity(state, vsock_path) do
          :ok ->
            Logger.info("Agent identity injected for VM #{state.id}")

          :skipped ->
            :ok

          {:error, reason} ->
            Logger.warning("Agent identity inject failed for VM #{state.id}: #{inspect(reason)}")
        end

        case maybe_inject_git_signing(state, vsock_path) do
          :ok ->
            Logger.info("Git signing key injected for VM #{state.id}")

          :skipped ->
            :ok

          {:error, reason} ->
            Logger.warning("Git signing inject failed for VM #{state.id}: #{inspect(reason)}")
        end

        # Tell guest agent whether to start Iroh. Skip the reconfigure in resume
        # mode if the guest already reports iroh ready — this avoids restarting
        # the iroh daemon and tearing down an otherwise-working endpoint.
        case maybe_configure_iroh(state, probe, vsock_path, state.enable_iroh) do
          :ok ->
            Logger.info(
              "Iroh #{if state.enable_iroh, do: "enabled", else: "disabled"} for VM #{state.id}"
            )

          :skipped ->
            Logger.info("Iroh already ready on resume, skipped for VM #{state.id}")

          {:error, reason} ->
            Logger.warning("configure_iroh failed: #{inspect(reason)}")
        end

        # Only wait for Iroh if enabled
        iroh_info =
          if state.enable_iroh do
            await_iroh_ready(vsock_path, 5_000)
          else
            nil
          end

        # The secrets_mode: :managed unlock USED to run here, inline. It now
        # runs off-process after do_boot returns — see start_secrets_unlock/1
        # and mjolnir-y32. do_boot's job ends at "the guest is reachable";
        # deciding when the VM becomes :running is handle_continue's.

        # Start persistent vsock connection for command execution
        {:ok, vsock_conn} =
          Mjolnir.Vsock.Connection.start_link(%{
            vm_id: state.id,
            socket_path: vsock_path
          })

        Process.delete(:boot_partial)

        {:ok,
         %{
           state
           | socket_path: socket_path,
             vsock_path: vsock_path,
             vsock_conn: vsock_conn,
             serial_path: serial_path,
             rootfs_path: rootfs_path,
             net_config: net_config,
             hypervisor_port: hv_port,
             virtiofsd_port: virtiofsd_port,
             extra_virtiofsd_ports: extra_virtiofsd_ports,
             iroh_node_id: iroh_info[:node_id],
             iroh_json: iroh_info[:ticket],
             ticket: Mjolnir.Ticket.from_hex(iroh_info[:node_id]),
             pty_ready: iroh_info != nil
         }}
      else
        error ->
          handle_boot_failure(state, error, socket_path, vsock_path, serial_path)
          error
      end

    result
  rescue
    e ->
      cleanup_partial_boot(state.hypervisor, nil, nil, nil)
      {:error, {:boot_exception, e}}
  end

  # On a boot failure, decide whether the freshly-cloned rootfs should be kept.
  #
  # For a FRESH spawn that failed for a *transient* reason (virtiofsd/CH
  # resource exhaustion, boot timeout, TAP allocation), we preserve the rootfs
  # and persist a :running intent record so Mjolnir.Reconcile resumes it on the
  # next Health.Monitor tick — instead of trashing it and giving up. Resume-mode
  # rootfs is never tracked, so it is already preserved.
  #
  # All other failures (permanent: bad base image, missing kernel) fall through
  # to the normal partial-boot cleanup, which soft-deletes the fresh clone.
  defp handle_boot_failure(state, error, socket_path, vsock_path, serial_path) do
    partial = Process.get(:boot_partial, %{})

    if not state.resume_mode and partial[:rootfs_path] && transient_boot_error?(error) do
      Logger.warning(
        "VM #{state.id}: transient boot failure (#{inspect(error)}); " <>
          "preserving rootfs and persisting :running record for Reconcile retry"
      )

      # Drop rootfs from the cleanup set so cleanup_partial_boot preserves it,
      # then persist intent so Reconcile owns recovery.
      Process.put(:boot_partial, Map.delete(partial, :rootfs_path))
      _ = persist_running_state(state)
    end

    cleanup_partial_boot(state.hypervisor, socket_path, vsock_path, serial_path)
  end

  # Recognize boot failures that are worth retrying (resource pressure, timing)
  # versus permanent misconfiguration. Conservative: an unrecognized error is
  # treated as permanent so we don't retry a genuinely broken config forever.
  @transient_boot_markers [
    "timeout",
    "virtiofsd",
    "eagain",
    "enomem",
    "emfile",
    "eaddrinuse",
    "resource temporarily unavailable",
    "cannot allocate memory",
    "too many open files",
    "address already in use",
    "no space left",
    "create_tap",
    "tap_",
    # TAP allocation races (a leftover mj-<id> interface from a prior instance
    # not yet reaped): `ip tuntap add ... ioctl(TUNSETIFF): Device or resource
    # busy`. Transient — the next sweep frees it.
    "tuntap",
    "tunsetiff",
    "device or resource busy"
  ]
  @permanent_boot_markers [
    "shared_dir_not_found",
    "resume_rootfs_missing",
    "snapshot_not_found",
    "btrfs_snapshot_failed"
  ]
  defp transient_boot_error?(error) do
    s = error |> inspect() |> String.downcase()

    cond do
      Enum.any?(@permanent_boot_markers, &String.contains?(s, &1)) -> false
      Enum.any?(@transient_boot_markers, &String.contains?(s, &1)) -> true
      true -> false
    end
  end

  defp boot_partial_put(key, value) do
    partial = Process.get(:boot_partial, %{})
    Process.put(:boot_partial, Map.put(partial, key, value))
  end

  defp cleanup_partial_boot(_hypervisor, socket_path, vsock_path, serial_path) do
    partial = Process.get(:boot_partial, %{})
    Process.delete(:boot_partial)

    Logger.debug("Cleaning up partially-created boot resources: #{inspect(Map.keys(partial))}")

    # Kill hypervisor port if started
    if partial[:hv_port] do
      try do
        case Port.info(partial.hv_port, :os_pid) do
          {:os_pid, os_pid} ->
            Port.close(partial.hv_port)
            System.cmd("kill", ["-9", to_string(os_pid)])

          nil ->
            :ok
        end
      rescue
        _ -> :ok
      end
    end

    # Stop virtiofsd if started
    if partial[:virtiofsd_port] do
      try do
        Mjolnir.VirtioFS.stop(partial.virtiofsd_port)
      rescue
        _ -> :ok
      end
    end

    # Stop extra virtiofsd instances if started
    if partial[:extra_virtiofsd_ports] do
      try do
        Enum.each(partial.extra_virtiofsd_ports, fn {_tag, port, _sock} ->
          Mjolnir.VirtioFS.stop(port)
        end)
      rescue
        _ -> :ok
      end
    end

    # Delete TAP if created
    if partial[:net_config] do
      try do
        Mjolnir.Network.delete_tap(partial.net_config.tap_name, partial.net_config.guest_ip)
      rescue
        _ -> :ok
      end
    end

    # Remove rootfs if cloned (fresh spawns only — resume mode never tracks it).
    # Soft-delete to @trash so a freshly-cloned rootfs lost to a transient boot
    # failure is recoverable rather than gone forever.
    if partial[:rootfs_path] do
      try do
        Mjolnir.BTRFS.trash_subvolume(partial.rootfs_path)
      rescue
        # May fail on macOS (no btrfs) -- that's OK for tests
        _ -> File.rm_rf(partial.rootfs_path)
      end
    end

    # Remove sockets
    if socket_path, do: File.rm(socket_path)
    if vsock_path, do: File.rm(vsock_path)
    if serial_path, do: File.rm(serial_path)

    :ok
  rescue
    _ -> :ok
  end

  defp inject_guest_agent(rootfs_dir) do
    agent_bin = Application.get_env(:mjolnir, :guest_agent_bin)

    if agent_bin && File.exists?(agent_bin) do
      dest = Path.join(rootfs_dir, "usr/local/bin/mjolnir-agent")
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(agent_bin, dest)
      File.chmod!(dest, 0o755)
      Logger.info("Injected current guest agent into rootfs")
    end

    :ok
  rescue
    e ->
      Logger.warning("Guest agent injection failed: #{inspect(e)}")
      :ok
  end

  defp stamp_freeze_metadata(name, state, metadata) do
    extra = %{
      kind: "memory",
      source_terminal: true,
      memory_bytes: metadata[:memory_bytes],
      memory_dir: metadata[:memory_dir],
      restore_config: jsonable_restore_config(state)
    }

    BTRFS.update_snapshot_metadata(name, extra)
  end

  defp jsonable_restore_config(state) do
    state
    |> restore_config()
    |> Map.new(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), jsonable_restore_value(v)}
      {k, v} -> {k, jsonable_restore_value(v)}
    end)
  end

  defp jsonable_restore_value(v) when is_atom(v), do: Atom.to_string(v)
  defp jsonable_restore_value(v), do: v

  defp do_thaw(state) do
    name = state.thaw_name
    socket_dir = Application.get_env(:mjolnir, :socket_dir)
    vsock_path = state.hypervisor.vsock_path(socket_dir, state.id)

    case Mjolnir.MemorySnapshot.thaw(name, state.id) do
      {:ok, thawed} ->
        case attach_thawed(state, thawed, vsock_path) do
          {:ok, _} = ok ->
            ok

          {:error, reason} ->
            abandon_thaw(state, thawed)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp attach_thawed(state, thawed, vsock_path) do
    guest_vsock = thawed.vsock_socket || vsock_path

    with :ok <- wait_for_boot(guest_vsock, state),
         {:ok, vsock_conn} <-
           Mjolnir.Vsock.Connection.start_link(%{
             vm_id: state.id,
             socket_path: guest_vsock
           }),
         :ok <- Mjolnir.Entropy.reseed(vsock_conn) do
      iroh_info =
        if state.enable_iroh do
          await_iroh_ready(guest_vsock, 5_000)
        else
          nil
        end

      {:ok,
       %{
         state
         | socket_path: thawed.api_socket,
           vsock_path: guest_vsock,
           vsock_conn: vsock_conn,
           rootfs_path: thawed.rootfs_path,
           net_config: thawed.net,
           hypervisor_port: thawed.hypervisor_port,
           virtiofsd_port: thawed.virtiofsd_port,
           extra_virtiofsd_ports: [],
           iroh_node_id: iroh_info[:node_id],
           iroh_json: iroh_info[:ticket],
           ticket: Mjolnir.Ticket.from_hex(iroh_info[:node_id]),
           pty_ready: iroh_info != nil
       }}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp abandon_thaw(state, thawed) do
    partial = %{
      state
      | hypervisor_port: thawed.hypervisor_port,
        virtiofsd_port: thawed.virtiofsd_port,
        net_config: thawed.net,
        rootfs_path: thawed.rootfs_path,
        socket_path: thawed.api_socket,
        vsock_path: thawed.vsock_socket
    }

    cleanup(partial, preserve_rootfs: false)
  end

  defp clone_rootfs(vm_id, base_image, config) do
    cond do
      config[:resume] ->
        # Resume mode: use the existing @vms/<uuid> subvolume left over from a
        # previous mjolnir run. If it's missing, the VM can't be rehydrated —
        # the caller (Mjolnir.Reconcile) should have checked first, so a missing
        # rootfs here is a bug or a race with manual cleanup.
        btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
        subdir = Application.get_env(:mjolnir, :vm_storage_subdir, "@vms")
        rootfs_path = Path.join([btrfs_root, subdir, vm_id])

        if File.exists?(rootfs_path) do
          {:ok, rootfs_path}
        else
          {:error, {:resume_rootfs_missing, rootfs_path}}
        end

      config.snapshot ->
        with {:ok, rootfs_path} <- BTRFS.clone_from_snapshot(config.snapshot, vm_id) do
          unless config.preserve_iroh_key do
            case BTRFS.delete_iroh_key(rootfs_path) do
              :ok -> :ok
              {:error, reason} -> Logger.warning("Failed to delete iroh key: #{inspect(reason)}")
            end
          end

          {:ok, rootfs_path}
        end

      true ->
        BTRFS.clone(base_image, vm_id)
    end
  end

  # Resume USED to skip this, and that quietly froze every long-lived VM at the
  # agent version its rootfs was born with. VM 2da0e442 was still running a
  # 2026-06-23 agent on 2026-08-13 — one that predates the `inject_secrets`
  # action entirely — so its managed-secrets unlock could never succeed. It
  # failed as a 60s :timeout rather than an error, because the old agent could
  # not deserialize the request and answered nothing (mjolnir-azm; the guest
  # now replies with an error, but only agents new enough to have that fix
  # will, which is exactly the bootstrapping problem this line creates).
  #
  # Injecting on resume is safe: the VM is not running yet — this is the boot
  # path, the rootfs subvolume is quiescent, and the write lands before the
  # hypervisor starts. Skipping it bought nothing and cost every VM its
  # upgrade path.
  defp maybe_inject_guest_agent(_state, rootfs_path), do: inject_guest_agent(rootfs_path)

  # --- Resume identity probe (option c) ---
  #
  # On resume, the guest already has network/ssh/identity/iroh configured from
  # its last boot. Re-pushing everything is idempotent for network/identity/ssh
  # but NOT for iroh (which restarts the daemon and tears down any live
  # connections). Probing first and skipping matched re-pushes saves ~1s and,
  # more importantly, preserves healthy iroh endpoints across resumes.

  defp probe_resume_state_safe(%__MODULE__{resume_mode: false}, _vsock_path), do: %{}

  defp probe_resume_state_safe(%__MODULE__{} = _state, vsock_path) do
    cmd = """
    echo "ROUTE=$(ip route show default 2>/dev/null | head -1 | awk '{print $3}')"
    echo "SSH_HASH=$(sha256sum /root/.ssh/authorized_keys 2>/dev/null | cut -d' ' -f1)"
    echo "IDENTITY=$([ -f /etc/mjolnir/vm.json ] && echo yes || echo no)"
    """

    request = %{
      "type" => "exec",
      "id" => :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower),
      "command" => cmd
    }

    case vsock_request(vsock_path, request, 5_000) do
      {:ok, %{"stdout" => output}} ->
        parse_probe_output(output)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp parse_probe_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [k, v] -> Map.put(acc, k, String.trim(v))
        _ -> acc
      end
    end)
  end

  defp maybe_configure_network(%__MODULE__{resume_mode: true}, probe, vsock_path, guest_ip) do
    case Map.get(probe, "ROUTE", "") do
      "" -> configure_guest_network(vsock_path, guest_ip)
      _ip -> :ok
    end
  end

  defp maybe_configure_network(_state, _probe, vsock_path, guest_ip) do
    configure_guest_network(vsock_path, guest_ip)
  end

  defp maybe_configure_ssh(%__MODULE__{resume_mode: true}, probe, vsock_path, ssh_key) do
    expected =
      :crypto.hash(:sha256, ssh_key <> "\n")
      |> Base.encode16(case: :lower)

    case Map.get(probe, "SSH_HASH") do
      ^expected -> :skipped
      _ -> configure_ssh(vsock_path, ssh_key)
    end
  end

  defp maybe_configure_ssh(_state, _probe, vsock_path, ssh_key),
    do: configure_ssh(vsock_path, ssh_key)

  # Always re-inject: blob_door_url must land on resume of guests that
  # booted before add-blob-door-overlay. Identity write is idempotent.
  defp maybe_configure_identity(_state, _probe, vsock_path, vm_id, api_url, blob_door_url),
    do: configure_identity(vsock_path, vm_id, api_url, blob_door_url)

  defp maybe_configure_iroh(%__MODULE__{resume_mode: true}, _probe, vsock_path, true) do
    case query_iroh_status(vsock_path) do
      {:ok, %{ready: true}} -> :skipped
      _ -> configure_iroh(vsock_path, true)
    end
  end

  defp maybe_configure_iroh(_state, _probe, vsock_path, enabled),
    do: configure_iroh(vsock_path, enabled)

  # In resume mode, the subvolume was created by a previous mjolnir run and
  # must NOT be torn down by cleanup_partial_boot on a retryable boot failure.
  # Only track rootfs in boot_partial for fresh spawns.
  defp track_rootfs_for_cleanup(%__MODULE__{resume_mode: true}, _rootfs_path), do: :ok

  defp track_rootfs_for_cleanup(_state, rootfs_path),
    do: boot_partial_put(:rootfs_path, rootfs_path)

  defp start_hypervisor(hypervisor, vm_id, socket_path, serial_path) do
    config = %{
      vm_id: vm_id,
      socket_path: socket_path,
      serial_path: serial_path
    }

    hypervisor.start_vm(config)
  end

  defp wait_for_socket(socket_path, timeout \\ 5000) do
    wait_for_socket(socket_path, timeout, System.monotonic_time(:millisecond))
  end

  defp wait_for_socket(socket_path, timeout, start_time) do
    if File.exists?(socket_path) do
      :ok
    else
      elapsed = System.monotonic_time(:millisecond) - start_time

      if elapsed > timeout do
        {:error, :socket_timeout}
      else
        Process.sleep(50)
        wait_for_socket(socket_path, timeout, start_time)
      end
    end
  end

  defp configure_vm(hypervisor, socket_path, config) do
    hypervisor.configure_vm(socket_path, config)
  end

  defp wait_for_boot(vsock_path, _state, timeout \\ 30_000) do
    start_time = System.monotonic_time(:millisecond)
    # Two-phase wait works for both legacy and initramfs modes:
    # - Legacy: first ping returns :full → done immediately
    # - Initramfs: first ping returns :boot → wait for :full after switch_root
    wait_for_agent(vsock_path, timeout, start_time)
  end

  defp wait_for_agent(vsock_path, timeout, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed > timeout do
      {:error, :boot_timeout}
    else
      case try_ping_agent(vsock_path) do
        {:ok, :full} ->
          Logger.debug("Guest agent (full) responded after #{elapsed}ms")
          :ok

        {:ok, :boot} ->
          Logger.debug("Boot agent responded after #{elapsed}ms, waiting for full agent")
          Process.sleep(500)
          wait_for_agent(vsock_path, timeout, start_time)

        {:error, _reason} ->
          Process.sleep(500)
          wait_for_agent(vsock_path, timeout, start_time)
      end
    end
  end

  defp await_iroh_ready(vsock_path, timeout) do
    # Poll the guest agent for Iroh status
    start_time = System.monotonic_time(:millisecond)
    do_await_iroh_ready(vsock_path, timeout, start_time)
  end

  defp do_await_iroh_ready(vsock_path, timeout, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed > timeout do
      Logger.warning("Timeout waiting for iroh_ready, shell access unavailable")
      nil
    else
      case query_iroh_status(vsock_path) do
        {:ok, %{ready: true} = info} ->
          Logger.info("VM PTY ready: node_id=#{info.node_id}")
          info

        {:ok, %{ready: false}} ->
          # Not ready yet, poll again
          Process.sleep(500)
          do_await_iroh_ready(vsock_path, timeout, start_time)

        {:error, _reason} ->
          # Connection failed, retry
          Process.sleep(500)
          do_await_iroh_ready(vsock_path, timeout, start_time)
      end
    end
  end

  defp query_iroh_status(vsock_path, timeout \\ 5_000) do
    request = Mjolnir.Vsock.Protocol.get_iroh_status_request()

    case vsock_request(vsock_path, request, timeout) do
      {:ok, response} -> parse_iroh_status_response(response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_iroh_status_response(%{
         "type" => "iroh_status",
         "ready" => true,
         "node_id" => node_id,
         "ticket" => ticket
       }) do
    {:ok, %{ready: true, node_id: node_id, ticket: ticket}}
  end

  defp parse_iroh_status_response(%{"type" => "iroh_status", "ready" => false}) do
    {:ok, %{ready: false}}
  end

  defp parse_iroh_status_response(other) do
    {:error, {:unexpected_response, other}}
  end

  defp configure_guest_network(vsock_path, guest_ip) do
    request = Mjolnir.Vsock.Protocol.configure_network_request(guest_ip)

    case vsock_request(vsock_path, request) do
      {:ok, %{"exit_code" => 0}} ->
        Logger.info("Guest network configured: #{guest_ip}")
        :ok

      {:ok, %{"exit_code" => code, "stderr" => stderr}} ->
        Logger.error("Guest network config failed (exit #{code}): #{stderr}")
        {:error, {:network_config_failed, code, stderr}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp configure_ssh(vsock_path, ssh_public_key) do
    request = Mjolnir.Vsock.Protocol.configure_ssh_request(ssh_public_key)

    case vsock_request(vsock_path, request) do
      {:ok, %{"exit_code" => 0}} ->
        :ok

      {:ok, %{"exit_code" => code, "stderr" => stderr}} ->
        {:error, {:ssh_config_failed, code, stderr}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp configure_identity(vsock_path, vm_id, api_url, blob_door_url) do
    request = Mjolnir.Vsock.Protocol.configure_identity_request(vm_id, api_url, blob_door_url)

    case vsock_request(vsock_path, request) do
      {:ok, %{"exit_code" => 0}} ->
        :ok

      {:ok, %{"exit_code" => code, "stderr" => stderr}} ->
        {:error, {:identity_config_failed, code, stderr}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp configure_iroh(vsock_path, enabled) do
    request = Mjolnir.Vsock.Protocol.configure_iroh_request(enabled)

    case vsock_request(vsock_path, request) do
      {:ok, %{"type" => "configure_iroh_response", "ok" => true}} ->
        :ok

      {:ok, %{"type" => "configure_iroh_response", "ok" => false}} ->
        {:error, :configure_iroh_rejected}

      {:ok, other} ->
        # Old agent that doesn't understand configure_iroh — treat as ok
        Logger.debug("Unexpected configure_iroh response: #{inspect(other)}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Runs a READ-ONLY vsock round-trip OFF the GenServer (mjolnir-75d, same
  # shape as the `:exec` clause from mjolnir-8ie). None of the `handle_call`
  # clauses using this touch `state`, so there is nothing to fold back in —
  # only the reply. spawn_monitor (not Task.start) so a crash cannot silently
  # swallow the reply; catches `:exit` so a dead Connection/guest replies with
  # an error instead of hanging the caller.
  defp reply_off_process(from, fun) when is_function(fun, 0) do
    :erlang.spawn_monitor(fn ->
      result =
        try do
          fun.()
        catch
          :exit, reason -> {:error, {:vsock_unavailable, reason}}
        end

      GenServer.reply(from, result)
    end)

    :ok
  end

  # Stops the old Vsock.Connection GenServer (if alive) and starts a fresh one
  # against the same UDS path. Runs entirely off the VM GenServer (called from
  # a spawned worker in `handle_call(:rebuild_vsock_connection, ...)`); it
  # touches no VM `state` itself — the caller folds the result back in from
  # `handle_info({:vsock_rebuild_result, _}, ...)`.
  defp do_rebuild_vsock_connection(vm_id, old_conn, vsock_path) do
    if old_conn && Process.alive?(old_conn) do
      try do
        GenServer.stop(old_conn, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end

    if vsock_path do
      Mjolnir.Vsock.Connection.start_link(%{vm_id: vm_id, socket_path: vsock_path})
    else
      {:error, :no_vsock_path}
    end
  end

  # secrets_mode: :managed — fetch (or generate+escrow) this VM's LUKS passphrase
  # and inject it over vsock. The guest is authoritative on create-vs-open (it
  # checks whether secrets.luks exists), so the host always sends the same
  # request; `init_size_mb` is only honored when the guest has to create. The
  # escrow entry is keyed by vm_id and lives off the data volume, so it survives
  # dormancy and is re-read on wake.
  defp maybe_unlock_secrets(%__MODULE__{secrets_mode: :managed} = state, vsock_path) do
    init_size = Application.get_env(:mjolnir, :secrets_volume_size_mb, 32)

    case Mjolnir.SecretEscrow.get_or_create(state.id) do
      {:ok, passphrase, origin} ->
        # Deliver secret material only on first creation — on wake (origin
        # :existing) it already lives inside the snapshot-carried LUKS volume.
        entries = if origin == :created, do: state.secrets_payload, else: nil

        request =
          Mjolnir.Vsock.Protocol.inject_secrets_request(passphrase,
            init_size_mb: init_size,
            entries: entries
          )

        # LUKS create (dd + argon2id format + mkfs) can exceed the default 10s.
        case vsock_request(vsock_path, request, 60_000) do
          {:ok, %{"ok" => true, "created" => created}} ->
            Logger.info(
              "Managed secrets #{if created, do: "created", else: "opened"} " <>
                "for VM #{state.id} (escrow #{origin})"
            )

            :ok

          {:ok, %{"ok" => false, "error" => err}} ->
            {:error, {:secrets_inject_rejected, err}}

          {:ok, other} ->
            Logger.warning(
              "Unexpected inject_secrets response for VM #{state.id}: #{inspect(other)}"
            )

            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:escrow_failed, reason}}
    end
  end

  defp maybe_unlock_secrets(_state, _vsock_path), do: :skipped

  # Re-inject Buzz identity every boot: /run/mjolnir/buzz.env is tmpfs.
  # The nsec is read from SecretStore for the request and not stored on state.
  defp maybe_inject_agent_identity(%__MODULE__{id: vm_id}, vsock_path) do
    case Mjolnir.Identity.get(vm_id) do
      {:ok, identity} ->
        request = Mjolnir.Vsock.Protocol.inject_identity_request(identity)

        case vsock_request(vsock_path, request, 10_000) do
          {:ok, %{"ok" => true}} ->
            :ok

          {:ok, %{"ok" => false, "error" => err}} ->
            {:error, {:identity_inject_rejected, err}}

          {:ok, _other} ->
            {:error, :unexpected_identity_response}

          {:error, reason} ->
            {:error, reason}
        end

      :not_found ->
        :skipped

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_inject_git_signing(%__MODULE__{id: vm_id}, vsock_path) do
    case Mjolnir.GitSigning.get(vm_id) do
      {:ok, pem} ->
        request = Mjolnir.GitSigning.inject_request(pem)

        case vsock_request(vsock_path, request, 10_000) do
          {:ok, %{"ok" => true}} ->
            :ok

          {:ok, %{"ok" => false, "error" => err}} ->
            {:error, {:git_signing_inject_rejected, err}}

          {:ok, _other} ->
            {:error, :unexpected_git_signing_response}

          {:error, reason} ->
            {:error, reason}
        end

      :not_found ->
        :skipped

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Watchdog slack over the 60s vsock bound inside maybe_unlock_secrets/2. Only
  # reached when the worker is stuck somewhere that bound does not cover.
  @secrets_unlock_watchdog_ms 90_000

  # Hand the managed-secrets unlock to a monitored worker and stay :booting
  # until it reports. The VM answers calls throughout — that is the entire
  # point (mjolnir-y32) — but it is NOT :running yet, because :running has to
  # keep meaning "the secrets volume is mounted" for
  # Mjolnir.Deploy.Orchestrator, which starts an app that sources
  # /run/mjolnir/secrets.env immediately after spawn returns.
  #
  # Non-:managed VMs have nothing to wait for and finish inline as before.
  defp start_secrets_unlock(%__MODULE__{secrets_mode: :managed} = state) do
    parent = self()
    vsock_path = state.vsock_path
    unlock_state = state

    # The result is correlated by the worker's pid, not the monitor ref: the
    # ref only exists once spawn_monitor returns, so the worker cannot name it
    # without a handshake. :DOWN and the watchdog still key on the ref.
    {pid, ref} =
      spawn_monitor(fn ->
        result =
          try do
            maybe_unlock_secrets(unlock_state, vsock_path)
          catch
            kind, reason -> {:error, {:unlock_crashed, kind, reason}}
          end

        send(parent, {:secrets_unlock_result, self(), result})
      end)

    timer =
      Process.send_after(self(), {:secrets_unlock_timeout, ref}, @secrets_unlock_watchdog_ms)

    {:noreply,
     %{state | secrets_unlock_ref: ref, secrets_unlock_pid: pid, secrets_unlock_timer: timer}}
  end

  defp start_secrets_unlock(state), do: finish_boot(state, nil)

  # Translate an unlock outcome into the struct field build_running_record/1
  # stamps. Log-and-continue is deliberate: a transient cryptsetup hiccup must
  # not wedge the boot. Before mjolnir-3v2 the log was the ONLY trace, and the
  # VM reported :running like any healthy one while /run/mjolnir never mounted.
  defp unlock_failure(_vm_id, :ok), do: nil
  defp unlock_failure(_vm_id, :skipped), do: nil

  defp unlock_failure(vm_id, {:error, reason}) do
    Logger.error("Managed secrets unlock failed for VM #{vm_id}: #{inspect(reason)}")
    %{reason: inspect(reason), at: DateTime.utc_now()}
  end

  # The single place a VM becomes :running. Reached directly for VMs with
  # nothing to unlock, and from each of the three unlock terminations.
  defp finish_boot(state, secrets_unlock_failure) do
    if is_reference(state.secrets_unlock_timer),
      do: Process.cancel_timer(state.secrets_unlock_timer)

    running_state = %{
      state
      | state: :running,
        boot_time: System.system_time(:millisecond),
        message_queue: [],
        secrets_unlock_failure: secrets_unlock_failure,
        secrets_unlock_ref: nil,
        secrets_unlock_pid: nil,
        secrets_unlock_timer: nil,
        boot_waiter: nil
    }

    persist_running_state(running_state)

    # spawn/1 blocks on await_boot. While the unlock ran, the mailbox was open,
    # so that call now lands on the :booting clause and parks here instead of
    # being answered by the :running clause after handle_continue returns.
    # Forgetting this reply would hang every managed spawn until its timeout.
    if state.boot_waiter, do: GenServer.reply(state.boot_waiter, {:ok, running_state})

    Mjolnir.Mailbox.kick(state.id)

    {:noreply, running_state}
  end

  # ============================================================================
  # Vsock Helpers - Synchronous request/response pattern
  # ============================================================================

  defp vsock_connect(vsock_path, timeout) do
    opts = [:binary, active: false, packet: :raw]

    with {:ok, sock} <- :gen_tcp.connect({:local, vsock_path}, 0, opts, timeout),
         :ok <- :gen_tcp.send(sock, "CONNECT 5000\n"),
         {:ok, response} <- :gen_tcp.recv(sock, 0, timeout) do
      if String.starts_with?(response, "OK") do
        {:ok, sock}
      else
        :gen_tcp.close(sock)
        {:error, {:vsock_connect_rejected, response}}
      end
    else
      {:error, reason} -> {:error, {:vsock_connect_failed, reason}}
    end
  end

  defp vsock_request(vsock_path, request_map, timeout \\ 10_000) do
    with {:ok, sock} <- vsock_connect(vsock_path, timeout) do
      message = Mjolnir.Vsock.Protocol.encode(request_map)
      :ok = :gen_tcp.send(sock, message)

      # Read the control response, skipping anything that is not ours.
      #
      # This used to take the next frame off the wire and hand its body
      # straight to Jason, discarding the channel byte — but every accepted
      # vsock connection makes the guest agent rebind /dev/log and start
      # draining it onto CHANNEL 2, and on a fresh boot that backlog (dbus,
      # systemd activation) can reach the wire before our channel-0 reply.
      # A syslog line then failed the JSON decode and killed the whole spawn
      # (mjolnir-pry). read_json_response/2 skips non-control frames and
      # undecodable ones, warns, and keeps reading within the same deadline.
      result = Mjolnir.Vsock.Protocol.read_json_response(sock, timeout)

      :gen_tcp.close(sock)
      result
    end
  end

  defp try_ping_agent(vsock_path) do
    alias Mjolnir.Vsock.Protocol
    ping_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    ping = %{"type" => "ping", "id" => ping_id}
    timeout = 2000

    # Same channel-blindness as vsock_request/3 above, and this one runs on
    # EVERY boot poll — the likeliest place to meet the guest's early syslog
    # backlog, and the observed failure in mjolnir-pry. The socket is closed on
    # every path, not only success: the old `:ok <- :gen_tcp.close(sock)` inside
    # the with-chain leaked the socket whenever a read failed.
    case vsock_connect(vsock_path, timeout) do
      {:ok, sock} ->
        try do
          with :ok <- :gen_tcp.send(sock, Protocol.encode(ping)),
               {:ok, %{"type" => "pong"} = pong} <-
                 Protocol.read_json_response(sock, timeout) do
            agent_type = if pong["agent"] == "boot", do: :boot, else: :full
            {:ok, agent_type}
          else
            {:ok, unexpected} -> {:error, {:unexpected_response, unexpected}}
            {:error, reason} -> {:error, reason}
          end
        after
          :gen_tcp.close(sock)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Synchronous exec for commands the VM runs on its OWN behalf from inside a
  # handle_call (e.g. the pre-snapshot `sync`). Bounded by default: this path
  # does block the mailbox, so an unbounded wait here is the mjolnir-8ie wedge.
  defp execute_command(state, command, timeout \\ @internal_exec_timeout) do
    if state.vsock_conn do
      try do
        Mjolnir.Vsock.Connection.exec(state.vsock_conn, command, timeout)
      catch
        :exit, reason -> {:error, {:vsock_unavailable, reason}}
      end
    else
      {:error, :no_vsock_connection}
    end
  end

  # The snapshot artifact exists, but the pause/resume around it can leave the
  # live guest wedged (mjolnir-l4i). When verification is enabled, rebuild the
  # vsock connection and confirm the guest survived; if it's genuinely wedged,
  # report loudly instead of a bare success (recovery is an operator `mj reboot`,
  # which CH's in-place reboot cannot safely do here). Gated by
  # :snapshot_verify_guest so test/headless paths skip the live-guest probe.
  defp verify_after_snapshot(state, name, metadata, opts) do
    # A caller can opt out per-snapshot (skip_verify: true) for a VM about to be
    # discarded, so a post-snapshot guest hiccup doesn't fail an intact snapshot
    # (mjolnir-8ie). The global :snapshot_verify_guest switch still gates the
    # probe overall; skip_verify is the narrower, call-site override.
    verify? =
      Application.get_env(:mjolnir, :snapshot_verify_guest, true) and
        not Keyword.get(opts, :skip_verify, false)

    if verify? do
      case verify_or_recover_guest(state) do
        {:ok, :healthy, new_state} ->
          {:reply, {:ok, metadata}, new_state}

        {:error, reason, new_state} ->
          Logger.error(
            "VM #{state.id}: guest unreachable after snapshot '#{name}': #{inspect(reason)}. " <>
              "Snapshot artifact is intact; recover the live VM with `mj reboot #{state.id}`."
          )

          {:reply, {:error, {:guest_unreachable_after_snapshot, reason, metadata}}, new_state}
      end
    else
      {:reply, {:ok, metadata}, state}
    end
  end

  # Confirm the guest agent survived the snapshot's pause/resume, rebuilding the
  # persistent vsock connection (which the pause/resume desyncs). Returns the
  # rebuilt state so the caller persists the fresh connection.
  defp verify_or_recover_guest(state) do
    # The pause/resume desyncs the long-lived vsock connection that exec/PTY use
    # even when the guest itself is fine — leaving the next exec to hang on a
    # stale socket (mjolnir-l4i). Rebuild it proactively so the connection is
    # fresh by the time the snapshot call returns.
    new_state = %{state | vsock_conn: rebuild_vsock_conn(state)}

    if guest_alive?(new_state) do
      {:ok, :healthy, new_state}
    else
      # Guest is genuinely wedged. We deliberately do NOT auto-reboot here: CH's
      # in-place vm.reboot cannot reconnect Mjolnir's external virtiofsd backend
      # and would destroy the VM (mjolnir-l4i). Report loudly; recovery is an
      # operator `mj reboot` (stop + resume from the preserved rootfs).
      {:error, :guest_unreachable, new_state}
    end
  end

  # Liveness probe via the L0 guest-agent ping. It opens its own fresh vsock
  # socket (independent of state.vsock_conn, which may itself have rotted), so
  # it is a true test of the guest. Retries a few times because a guest may need
  # a moment to settle after a resume/reboot before the agent answers.
  defp guest_alive?(state, attempts \\ 3)

  defp guest_alive?(%__MODULE__{} = state, attempts) when attempts > 0 do
    case Mjolnir.Health.GuestAgentPing.probe(state) do
      :ok ->
        true

      _other when attempts > 1 ->
        Process.sleep(1_000)
        guest_alive?(state, attempts - 1)

      _other ->
        false
    end
  end

  defp guest_alive?(_state, _attempts), do: false

  # vm_id variant used by revive/1 from outside the GenServer. Fetches state via
  # get/1 (which is itself timeout-safe); a blocked GenServer reads as not
  # reachable, which correctly routes revive to the reboot path.
  defp guest_reachable?(vm_id) when is_binary(vm_id) do
    case get(vm_id) do
      {:ok, vm} -> guest_alive?(vm, 1)
      _ -> false
    end
  end

  # Kill the cloud-hypervisor process serving this VM's API socket at the OS
  # level. This works even when the VM GenServer mailbox is blocked (a wedged
  # guest can leave an :infinity exec stuck in the mailbox). The resulting port
  # exit makes the GenServer terminate via its preserve-rootfs path, cleaning up
  # the TAP/virtiofsd/sockets while keeping the @vms subvolume for resume/1.
  defp kill_hypervisor_process(vm_id) do
    # Match the CH process precisely by the VM's UUID (it appears in the
    # --api-socket path) so we never touch another VM's hypervisor. Best-effort:
    # a missing match is fine (process already dead, or a unit test with no CH).
    pattern = "cloud-hypervisor.*#{vm_id}"

    case System.cmd("pkill", ["-9", "-f", pattern], stderr_to_stdout: true) do
      {_, 0} -> Logger.info("VM #{vm_id}: killed hypervisor process for reboot")
      {_, 1} -> Logger.info("VM #{vm_id}: no hypervisor process matched for reboot")
      {out, code} -> Logger.warning("VM #{vm_id}: pkill exited #{code}: #{String.trim(out)}")
    end
  rescue
    e -> Logger.warning("VM #{vm_id}: kill_hypervisor_process raised: #{inspect(e)}")
  end

  # Poll until the VM has no live GenServer in the registry (its terminate has
  # run and cleaned up), up to `timeout_ms`. Returns true once gone.
  defp wait_until_deregistered(vm_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_deregistered(vm_id, deadline)
  end

  defp do_wait_until_deregistered(vm_id, deadline) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [] ->
        true

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          Process.sleep(200)
          do_wait_until_deregistered(vm_id, deadline)
        end
    end
  end

  # Stop the (now stale) persistent vsock connection and start a fresh one
  # against the same UDS path. Mirrors handle_call(:rebuild_vsock_connection).
  defp rebuild_vsock_conn(state) do
    _ =
      if state.vsock_conn && Process.alive?(state.vsock_conn) do
        try do
          GenServer.stop(state.vsock_conn, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end

    case Mjolnir.Vsock.Connection.start_link(%{vm_id: state.id, socket_path: state.vsock_path}) do
      {:ok, conn} ->
        conn

      {:error, reason} ->
        Logger.error("Reboot reattach: vsock connection rebuild failed: #{inspect(reason)}")
        nil
    end
  end

  defp do_snapshot(state, name, opts) do
    # Step 1: Flush guest caches
    case execute_command(state, "sync") do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("Guest sync failed: #{inspect(reason)}")
    end

    # Step 2: Pause VM to stop writes
    case state.hypervisor.pause_instance(state.socket_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to pause VM for snapshot: #{inspect(reason)}")
        {:error, {:pause_failed, reason}}
    end
    |> case do
      :ok ->
        try do
          # No host-side fsync needed: guest sync is performed above, and
          # btrfs subvolume snapshot is atomic at the filesystem level.

          with :ok <- maybe_scrub_hosted_key(state, name) do
            BTRFS.create_snapshot(state.id, name,
              source_vm_id: state.id,
              owner_id: opts[:owner_id] || state.owner_id
            )
          end
        after
          # Step 6: Always resume
          case state.hypervisor.resume_instance(state.socket_path) do
            :ok ->
              Logger.debug("VM #{state.id} resumed after snapshot")

            {:error, reason} ->
              Logger.error("Failed to resume VM #{state.id} after snapshot: #{inspect(reason)}")
          end
        end

      error ->
        error
    end
  end

  defp maybe_scrub_hosted_key(state, name) do
    if Mjolnir.HonorBeing.KeyScrub.hosted_snapshot_name?(name) do
      rootfs = state.rootfs_path || Mjolnir.Reconcile.rootfs_path(state.id)

      case Mjolnir.HonorBeing.KeyScrub.scrub_rootfs(rootfs) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("Hosted-being key scrub failed for #{state.id}: #{inspect(reason)}")
          {:error, {:key_scrub_failed, reason}}
      end
    else
      :ok
    end
  end

  defp cleanup(state, opts) do
    preserve_rootfs = Keyword.get(opts, :preserve_rootfs, false)

    # The hypervisor's cleanup/1 only deletes the subvolume when state.rootfs_path
    # is set. Nilling it lets us keep the rest of the teardown (CH process, TAP,
    # sockets, virtiofsd) while preserving rootfs for Mjolnir.Reconcile.
    effective_state = if preserve_rootfs, do: %{state | rootfs_path: nil}, else: state

    if state.hypervisor do
      state.hypervisor.cleanup(effective_state)
    else
      Logger.warning("No hypervisor set for VM #{state.id}, skipping cleanup")
    end

    :ok
  rescue
    _ -> :ok
  end

  # Build the durable :running record from live VM state. Shared by
  # persist_running_state/1 and the trash-metadata sidecar so a restored VM
  # carries the same spawn_config Reconcile needs to resume it.
  #
  # Public (not private) so mjolnir-3v2's "survives a rebuild" guarantee can
  # be exercised directly against a hand-built %Mjolnir.VM{} struct in tests,
  # the same way Mjolnir.CILease.stamp_runtime/3 is tested directly rather
  # than through a full VM boot.
  @doc false
  @spec build_running_record(t()) :: Mjolnir.StateStore.Record.t()
  def build_running_record(state) do
    Mjolnir.StateStore.Record.new(state.id, :running,
      spawn_config: %{
        "vcpus" => state.config.vcpu_count,
        "memory_mb" => state.config.mem_size_mib,
        "base_image" => state.config.base_image,
        "enable_iroh" => state.enable_iroh,
        "owner_id" => state.owner_id,
        "ssh_public_key" => state.ssh_public_key,
        "secrets_mode" => Atom.to_string(state.secrets_mode),
        # Reconcile reads this back to decide whether a stranded record may be
        # rehydrated. It has to be on the FIRST record written, not added later:
        # a crash between boot and a second write would leave a :never VM
        # looking restartable, which is exactly the I5 violation this prevents.
        "restart_policy" => Atom.to_string(state.restart_policy)
      },
      identity: %{
        "iroh_node_id" => state.iroh_node_id,
        "hostname" => nil,
        "ssh_authorized_keys_hash" => nil
      },
      # Stamped with a CI lease when this VM is CI-owned, and with the
      # mjolnir-3v2 secrets-unlock outcome when the current boot's managed
      # unlock failed. This map is rebuilt from scratch on every boot and
      # resume, so a lease written by CILease.renew/2 would otherwise be lost
      # on restart — and a CI VM with no lease is never reclaimable
      # (mjolnir-urp fails closed on absence), which is how orphaned CI VMs
      # used to accumulate across restarts. Same trap applies to the secrets-
      # unlock flag: it MUST be stamped in here from `state`, not written to
      # StateStore separately, or the next boot/resume silently erases it.
      runtime:
        %{
          "ch_api_socket" => state.socket_path,
          "vsock_uds" => state.vsock_path
        }
        |> Mjolnir.CILease.stamp_runtime(state.metadata)
        |> stamp_secrets_unlock_runtime(state.secrets_unlock_failure),
      metadata: state.metadata,
      last_boot_at: DateTime.utc_now()
    )
  end

  @doc false
  @spec stamp_secrets_unlock_runtime(map(), map() | nil) :: map()
  def stamp_secrets_unlock_runtime(runtime, nil) when is_map(runtime), do: runtime

  def stamp_secrets_unlock_runtime(runtime, %{reason: reason, at: at})
      when is_map(runtime) do
    Map.merge(runtime, %{
      "secrets_unlock_failed" => true,
      "secrets_unlock_error" => reason,
      "secrets_unlock_failed_at" => DateTime.to_iso8601(at)
    })
  end

  defp persist_running_state(state) do
    record = build_running_record(state)

    case Mjolnir.StateStore.put(record) do
      :ok ->
        :ok

      {:error, reason} ->
        # Durability failure is logged but does not fail the VM — the VM is
        # running, we just won't be able to resurrect it on mjolnir restart.
        Logger.warning(
          "Failed to persist StateStore record for VM #{state.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # ============================================================================
  # Dormant VM Helpers
  # ============================================================================

  defp restore_config(state) do
    %{
      base_image: state.config.base_image,
      vcpus: state.config.vcpu_count,
      memory_mb: state.config.mem_size_mib,
      enable_iroh: state.enable_iroh,
      ssh_public_key: state.ssh_public_key,
      owner_id: state.owner_id,
      secrets_mode: state.secrets_mode,
      restart_policy: state.restart_policy
    }
  end

  defp normalize_config_keys(config) do
    Map.new(config, fn
      {k, v} when is_binary(k) ->
        if k in @config_key_allowlist, do: {String.to_atom(k), v}, else: {k, v}

      {k, v} ->
        {k, v}
    end)
  end

  defp restore_dormant_vm(vm_id) do
    case Mjolnir.DormantRegistry.begin_restore(vm_id) do
      :ok ->
        Task.Supervisor.start_child(Mjolnir.TaskSupervisor, fn ->
          do_restore_dormant_vm(vm_id)
        end)

        :ok

      :already_restoring ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_restore_dormant_vm(vm_id) do
    case Mjolnir.DormantRegistry.lookup(vm_id) do
      {:ok, entry} ->
        # Spawn the VM from its dormant snapshot, reusing the same VM ID
        opts =
          entry.original_config
          |> normalize_config_keys()
          |> Map.merge(%{
            id: vm_id,
            snapshot: entry.snapshot_name,
            preserve_iroh_key: false
          })

        case spawn_with_id(opts) do
          {:ok, _vm} ->
            # Absorb any pre-mailbox pending_messages into the spool (one-time
            # migration for VMs that went dormant before this change).
            pending = Mjolnir.DormantRegistry.take_pending_messages(vm_id)
            Mjolnir.DormantRegistry.unregister(vm_id)

            for {from_vm_id, payload} <- pending do
              _ = Mjolnir.Mailbox.accept(vm_id, from_vm_id, payload)
            end

            Mjolnir.Mailbox.kick(vm_id)

            Mjolnir.EventBus.publish(vm_id, :vm_restored, %{from_snapshot: entry.snapshot_name})
            Logger.info("Successfully restored dormant VM #{vm_id}")

          {:error, reason} ->
            Logger.error("Failed to restore dormant VM #{vm_id}: #{inspect(reason)}")
            Mjolnir.DormantRegistry.cancel_restore(vm_id)
        end

      :not_found ->
        Logger.warning("Dormant VM #{vm_id} not found during restore")
    end
  end
end

defimpl Inspect, for: Mjolnir.VM do
  def inspect(%Mjolnir.VM{} = vm, opts) do
    payload =
      case vm.secrets_payload do
        nil -> nil
        _ -> :redacted
      end

    Inspect.Algebra.concat([
      "#Mjolnir.VM<",
      Inspect.Algebra.to_doc(
        [id: vm.id, state: vm.state, secrets_payload: payload],
        opts
      ),
      ">"
    ])
  end
end
