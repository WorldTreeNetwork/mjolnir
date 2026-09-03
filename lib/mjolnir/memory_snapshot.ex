defmodule Mjolnir.MemorySnapshot do
  @moduledoc """
  Real freeze/thaw: guest RAM captured with the filesystem, as one artifact.

  `Mjolnir.VM.snapshot/2` is a *filesystem* snapshot. A VM "restored" from one
  is a cold boot off a snapshotted disk — every running process, open socket
  and unwritten buffer is gone. This module is the other half: it captures the
  guest's memory too, so a thawed VM resumes mid-instruction rather than
  booting.

  ## Freeze is a one-way park, not a checkpoint

  Read `freeze/3` before using this. `vm.snapshot` is **terminal for the source
  VM**: any VM with a vhost-user device (i.e. every Mjolnir VM, since the
  rootfs is virtio-fs) wedges on its first filesystem I/O afterwards, even
  though CH reports it as `Running`. Freeze parks a VM; `thaw/3` brings it back
  in a fresh VMM. There is no "snapshot it and keep serving" — that is what the
  filesystem-only `Mjolnir.VM.snapshot/2` is for.

  ## The invariant this module exists to hold

  Guest RAM contains a page cache that believes in a specific on-disk state.
  If the filesystem the guest wakes up on is not byte-identical to the one it
  was captured against, the kernel's cached inodes describe blocks that no
  longer say what it thinks. That is silent corruption, not a crash.

  Flushing does not fix it. `sync` writes back *dirty* pages; the hazard is
  *clean* cached pages, which the guest keeps and has no reason to re-read.
  `drop_caches` does not fix it either — it cannot evict mmap'd or in-use pages
  (every running binary's text pages), so it trades a correctness hole for a
  cold-cache cliff and still leaves the hole.

  **The fix is immutability.** Three rules, all enforced here:

  1. The BTRFS snapshot and the CH memory snapshot are taken inside a *single
     pause window*. Nothing can write between them because no vCPU is running.
  2. The filesystem snapshot is created **read-only** (`btrfs subvolume
     snapshot -r`), so it cannot drift afterwards.
  3. Restore **never** points virtiofsd at the live `@vms/<id>` subvolume —
     which is what the normal boot path does. It clones the pinned snapshot to
     a fresh subvolume and serves that. A thaw that mounted the live rootfs
     would hand the guest a filesystem that had kept moving since capture.

  Rule 3 is the one that is easy to get wrong by accident, because pointing at
  the live subvolume is what every other code path correctly does.

  Generation pinning backstops all three: the snapshot's BTRFS generation is
  recorded at capture and re-checked at thaw. A read-only subvolume's
  generation never advances, so a mismatch means someone flipped it writable
  and modified it. `thaw/3` refuses rather than booting something corrupt.

  ## Restore ordering

  CH cannot restore into a VM that has been created or booted, and it
  *reconnects* to vhost-user backends rather than respawning them. So the
  sequence is not negotiable:

  1. Verify the snapshot generation, then clone it to a fresh subvolume
  2. Start virtiofsd on that clone, on the socket path the snapshot recorded
  3. Start a fresh `cloud-hypervisor` with `--api-socket` and *no* `--vm-config`
  4. `vm.restore` — the VM comes back **paused**
  5. `vm.resume`
  6. Reseed guest entropy (`Mjolnir.Entropy`), reopen secrets if they were
     suspended (`Mjolnir.Secrets.Quiesce.resume/3` or the existing
     `inject_secrets` path — it resumes a suspended mapper), then publish
     reachability

  Note the ordering of 5 and 6. The reseed cannot precede the resume: it is
  serviced by the guest agent, which is a userspace process that cannot run
  while vCPUs are stopped. The gate is therefore on **reachability**, not on
  execution — no PTY, no ticket, no gateway route until the guest confirms.
  See `Mjolnir.Entropy` for what that does and does not buy.

  ## Cost

  A BTRFS snapshot is effectively free (CoW). A memory snapshot is the guest's
  full RAM, uncompressed, every time — a 2 GiB VM writes 2 GiB. Memory and
  filesystem snapshots are complementary, not substitutes, and callers should
  choose deliberately.
  """

  require Logger

  # virtiofsd binds its socket within milliseconds of exec; 5s is already a
  # "this daemon is not coming up" verdict rather than a tight race.
  @backend_socket_timeout_ms 5_000

  alias Mjolnir.BTRFS
  alias Mjolnir.CloudHypervisor.Client

  @doc """
  Directory holding a named memory snapshot's CH artifacts.

  Deliberately a sibling of the `@snapshots/<name>` subvolume rather than a
  path inside it: the subvolume is read-only, and CH must be able to write
  `config.json`, `state.json` and `memory-ranges`.
  """
  @spec memory_dir(String.t()) :: String.t()
  def memory_dir(name) do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    Path.join([btrfs_root, "@snapshots", "#{name}.mem"])
  end

  @doc """
  Whether `name` is a memory snapshot (as opposed to filesystem-only).

  Callers use this to decide between thaw and cold boot, so it asks the
  question that actually matters — "are the memory artifacts on disk?" — not
  "does metadata claim they are".
  """
  @spec memory_snapshot?(String.t()) :: boolean()
  def memory_snapshot?(name) do
    File.exists?(Path.join(memory_dir(name), "state.json"))
  end

  @doc """
  Freeze a running VM: capture filesystem and guest RAM as one artifact.

  `vm` must carry `:id` and `:socket_path` (the CH API socket).

  ## FREEZING IS A ONE-WAY PARK. THE SOURCE VM DOES NOT COME BACK.

  This is the single most surprising property of the whole mechanism, and it is
  a hypervisor constraint rather than a choice. **`vm.snapshot` is terminal for
  any VM with a vhost-user device** — which is every Mjolnir VM, because the
  rootfs is virtio-fs.

  Measured on the host: after `vm.pause` → `vm.snapshot` → `vm.resume`, CH
  reports `state: Running` and a second `vm.resume` returns 500 ("already
  running"), yet the guest executes nothing. A 1/second tick in the guest
  stopped dead and never advanced; `vcpu0` sat in `kvm_vcpu_block` waiting for
  an interrupt that never came while the `_fs0` thread idled in `ep_poll`. The
  guest had blocked on its first post-snapshot filesystem I/O and everything
  else stalled behind it. A plain `pause` → 15s → `resume` on the same VM is
  completely fine, so it is the snapshot that does it, not the pause.

  Not caused by `--migration-mode=find-paths`, which was the obvious suspect:
  the same wedge happens with virtiofsd started without it (CH asks the backend
  to serialize either way).

  So this function does **not** resume the source, and deliberately does not
  pretend to. An earlier version called `vm.resume` in an `after` block and
  logged success — which is worse than useless: it returns 204, leaves CH
  reporting `Running`, and hands back a VM that health checks will call alive
  while nothing inside it executes. Callers must treat a frozen VM as finished
  and tear it down; to get it back, `thaw/3` it into a fresh VMM.

  This suits the DormantRegistry use case exactly — park an idle VM to disk,
  thaw it mid-thought. It does **not** support "checkpoint a running VM and
  keep serving from it". For a non-disruptive checkpoint use the
  filesystem-only `Mjolnir.VM.snapshot/2`, which pauses only briefly and does
  resume cleanly.

  ## Options

    - `:owner_id` — recorded on the snapshot metadata
    - `:pause_fun` — 1-arity override taking the API socket path, so a caller
      holding a hypervisor module can route through it instead of
      `Mjolnir.CloudHypervisor.Client` directly
    - `:quiesce_fun` — 2-arity override `(vm, secrets_mode -> {:ok, map} |
      {:error, term})` run **before** pause. Default talks to the guest
      over vsock when `secrets_mode` is `:managed` or `:persistent`. A
      secrets VM cannot take a naive memory snapshot: freeze refuses if
      the key cannot be wiped.
    - `:secrets_mode` — override; otherwise read from `vm.secrets_mode`

  Returns `{:ok, metadata}` — the BTRFS sidecar plus `:memory_dir`,
  `:memory_bytes`, `:secrets_suspended`, and `:source_terminal` (always
  `true`, so a caller cannot read the result as "still running" by omission).
  """
  @spec freeze(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def freeze(vm, name, opts \\ []) do
    socket = vm.socket_path
    pause = Keyword.get(opts, :pause_fun, &Client.pause_vm/1)
    quiesce = Keyword.get(opts, :quiesce_fun, &default_quiesce/2)
    mem_dir = memory_dir(name)
    secrets_mode = secrets_mode(vm, opts)

    if File.exists?(mem_dir) do
      {:error, {:snapshot_exists, name}}
    else
      # Quiesce BEFORE pause. luksSuspend is a guest-userspace call; once
      # vCPUs stop, the agent cannot wipe the key, and the snapshot would
      # capture it. A failed wipe leaves the VM running.
      case quiesce.(vm, secrets_mode) do
        {:ok, quiesce_info} ->
          case pause.(socket) do
            :ok ->
              # Everything from here runs with no vCPU scheduled. That is the
              # whole correctness argument: the guest cannot write to the
              # filesystem between the BTRFS snapshot and the RAM capture, so
              # the two describe the same instant.
              #
              # There is no `after resume` because there is no resume — see
              # the moduledoc above. The pause is not a window we exit; it
              # is the end of this VM's life in this VMM.
              case capture(vm, name, mem_dir, opts) do
                {:ok, metadata} ->
                  _ = write_secrets_sidecar(mem_dir, quiesce_info)

                  Logger.info(
                    "VM #{vm.id} is now PARKED — vm.snapshot is terminal for a virtio-fs VM. " <>
                      "Tear it down; thaw '#{name}' into a fresh VMM to get it back."
                  )

                  {:ok,
                   metadata
                   |> Map.put(:source_terminal, true)
                   |> Map.put(:secrets_suspended, Map.get(quiesce_info, :suspended, false))}

                {:error, reason} ->
                  # The VM is left paused and, having been snapshotted or
                  # partially snapshotted, may already be unable to continue.
                  # Say so rather than implying a resume would fix it.
                  Logger.error(
                    "Freeze of VM #{vm.id} failed: #{inspect(reason)}. The VM is paused and may " <>
                      "not be resumable; treat it as parked and tear it down."
                  )

                  {:error, reason}
              end

            {:error, reason} ->
              # Nothing was captured and no snapshot was taken, so the VM is
              # untouched apart from a failed pause attempt.
              {:error, {:pause_failed, reason}}
          end

        {:error, {:secrets_quiesce_required, _} = reason} ->
          {:error, reason}

        {:error, reason} ->
          {:error, {:secrets_quiesce_failed, reason}}
      end
    end
  end

  # A :managed/:persistent VM must not be snapshotted with the DEK still in
  # RAM. No vsock and no override is a refusal, not a skip. Other modes have
  # nothing to wipe.
  defp default_quiesce(vm, mode) when mode in [:managed, :persistent] do
    case vsock_path(vm) do
      path when is_binary(path) -> Mjolnir.Secrets.Quiesce.suspend(path)
      _ -> {:error, {:secrets_quiesce_required, mode}}
    end
  end

  defp default_quiesce(_vm, _mode), do: {:ok, %{suspended: false}}

  defp secrets_mode(vm, opts) do
    Keyword.get(opts, :secrets_mode) || Map.get(vm, :secrets_mode) || :none
  end

  defp vsock_path(vm) when is_map(vm) do
    Map.get(vm, :vsock_path)
  end

  defp capture(vm, name, mem_dir, opts) do
    # Filesystem first, RAM second. Order within the pause window does not
    # affect correctness (nothing is running), but this way a failure in the
    # expensive RAM write leaves no half-written memory dir next to a
    # perfectly good filesystem snapshot that something might later mistake
    # for a complete artifact.
    with {:ok, metadata} <-
           BTRFS.create_snapshot(vm.id, name,
             source_vm_id: vm.id,
             owner_id: opts[:owner_id],
             readonly: true
           ),
         :ok <- File.mkdir_p(mem_dir),
         :ok <- Client.snapshot_vm(vm.socket_path, mem_dir) do
      metadata =
        metadata
        |> Map.put(:memory_dir, mem_dir)
        |> Map.put(:memory_bytes, dir_bytes(mem_dir))

      Logger.info(
        "Froze VM #{vm.id} as '#{name}' " <>
          "(generation #{metadata.generation}, #{metadata.memory_bytes} bytes of RAM)"
      )

      {:ok, metadata}
    else
      {:error, reason} ->
        # Leave nothing that could later be read as a usable memory snapshot.
        _ = File.rm_rf(mem_dir)
        Logger.error("Memory snapshot '#{name}' failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Prepare a thaw: verify the pin and clone the frozen filesystem.

  Returns `{:ok, %{rootfs_path: path, memory_dir: dir, metadata: map}}`. The
  caller starts virtiofsd against `rootfs_path` and a fresh cloud-hypervisor,
  then calls `restore/2`.

  This is where rule 3 is enforced: the returned `rootfs_path` is a **fresh
  clone** under `@vms/<new_vm_id>`, never the live subvolume of the VM that was
  frozen, and never the read-only snapshot itself (virtiofsd needs to write).

  Refuses with `{:error, {:snapshot_drifted, name, expected, actual}}` if the
  frozen filesystem has been modified since capture, and with
  `{:error, {:snapshot_generation_unknown, name}}` if the snapshot predates
  generation recording — an unprovable pin is treated as a failed pin, because
  the alternative is booting a guest onto a filesystem it may disagree with.
  """
  @spec prepare_thaw(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare_thaw(name, new_vm_id) do
    mem_dir = memory_dir(name)

    with :ok <- ensure_memory_artifacts(name, mem_dir),
         :ok <- BTRFS.verify_pin(name),
         {:ok, %{metadata: metadata}} <- BTRFS.get_snapshot(name),
         {:ok, rootfs_path} <- BTRFS.clone_from_snapshot(name, new_vm_id, verify_pin: true) do
      Logger.info(
        "Thaw prepared for '#{name}' → VM #{new_vm_id} at generation #{metadata[:generation]}"
      )

      {:ok, %{rootfs_path: rootfs_path, memory_dir: mem_dir, metadata: metadata}}
    end
  end

  defp ensure_memory_artifacts(name, mem_dir) do
    if File.exists?(Path.join(mem_dir, "state.json")) do
      :ok
    else
      {:error, {:memory_snapshot_not_found, name}}
    end
  end

  @doc """
  Issue `vm.restore` against a fresh, unbooted cloud-hypervisor API socket.

  The VM comes back **paused**. It stays paused so entropy can be reseeded
  before any userspace runs — do not resume here.
  """
  @spec restore(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def restore(api_socket, memory_dir, opts \\ []) do
    Client.restore_vm(api_socket, memory_dir, opts)
  end

  # ==========================================================================
  # Restore orchestration (mjolnir-3y6.4) — hazards 2 and 5
  # ==========================================================================

  @doc """
  Read the `config.json` Cloud Hypervisor wrote alongside the memory image.

  This file is the authority on what a restore *requires*, and it is not
  optional reading: it records **absolute** socket paths and the vsock CID that
  CH will reconnect to, verbatim. Confirmed against a real v53 snapshot:

      "fs":    [{"id": "_fs0", "tag": "myfs", "socket": "/tmp/x/fs.sock", ...}]
      "vsock": {"id": "_vsock1", "cid": 78123499, "socket": "/tmp/x/vsock"}
      "net":   [{"tap": "mj-...", "mac": "02:...", ...}]

  So the backends cannot simply be brought up wherever the new VM would
  normally put them — they have to be brought up exactly where the *frozen* VM
  had them.
  """
  @spec read_snapshot_config(String.t()) :: {:ok, map()} | {:error, term()}
  def read_snapshot_config(memory_dir) do
    path = Path.join(memory_dir, "config.json")

    with {:ok, body} <- File.read(path),
         {:ok, config} <- Jason.decode(body) do
      {:ok, config}
    else
      {:error, :enoent} -> {:error, {:snapshot_config_missing, path}}
      {:error, reason} -> {:error, {:snapshot_config_unreadable, path, reason}}
    end
  end

  @doc """
  Extract the host-side resources a restore requires from a snapshot config.

  Returns `{:ok, %{fs_socket:, extra_fs_sockets:, vsock_socket:, vsock_cid:,
  tap:, mac:}}`. `tap`/`mac` are `nil` for a VM snapshotted without networking.

  Fails with `{:snapshot_config_no_fs, config}` rather than defaulting: a
  Mjolnir VM's rootfs is always virtio-fs, so a snapshot without an `fs` device
  is not one of ours and guessing a socket path would produce a restore that
  hangs on first I/O instead of an error anyone can read.
  """
  @spec required_backends(map()) :: {:ok, map()} | {:error, term()}
  def required_backends(config) do
    case config["fs"] do
      [%{"socket" => primary} | rest] when is_binary(primary) ->
        {:ok,
         %{
           fs_socket: primary,
           extra_fs_sockets: for(%{"socket" => s} <- rest, is_binary(s), do: s),
           vsock_socket: get_in(config, ["vsock", "socket"]),
           vsock_cid: get_in(config, ["vsock", "cid"]),
           tap: get_in(config, ["net", Access.at(0), "tap"]),
           mac: get_in(config, ["net", Access.at(0), "mac"])
         }}

      _ ->
        {:error, {:snapshot_config_no_fs, Map.keys(config)}}
    end
  end

  @doc """
  Directory holding a remapped copy of a named memory snapshot, for one thaw
  identity.

  Sibling of `@snapshots/<name>.mem` rather than a subdirectory of it: CH
  restore reads `config.json` / `state.json` / `memory-ranges` from a directory
  and extra entries in the original artifact must not be confused with those.
  """
  @spec fork_dir(String.t(), String.t()) :: String.t()
  def fork_dir(name, new_vm_id) do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    Path.join([btrfs_root, "@snapshots", "#{name}.mem.forks", new_vm_id])
  end

  @doc """
  Rewrite a CH `config.json` so a thaw can run under a new identity.

  The original snapshot records absolute virtiofsd/vsock socket paths and a
  vsock CID. Two thaws of that file collide — the second attaches to the
  first VM's virtiofsd. Proven on CH v53 (mjolnir-8m3): restore accepts a
  rewritten config with a different socket path *and* a different CID while
  `state.json` still describes the original devices.

  What this changes:

    - `fs[].socket` — per-identity virtiofsd path (`VirtioFS.socket_path/2,3`)
    - `vsock.socket` / `vsock.cid` — per-identity vsock
    - `net[].tap` — per-identity TAP name, **MAC kept** (guest-visible, in RAM)

  What this does not change: guest IP, hostname, machine-id, Iroh key. Those
  are `mjolnir-8m3`. Exec over vsock does not need them, which is why the
  entropy probe can run without a full fork.
  """
  @spec remap_config(map(), String.t(), String.t()) :: map()
  def remap_config(config, new_vm_id, socket_dir)
      when is_map(config) and is_binary(new_vm_id) and is_binary(socket_dir) do
    config
    |> remap_fs(new_vm_id, socket_dir)
    |> remap_vsock(new_vm_id, socket_dir)
    |> remap_tap(new_vm_id)
  end

  defp remap_fs(config, vm_id, socket_dir) do
    case config["fs"] do
      fs when is_list(fs) ->
        remapped =
          fs
          |> Enum.with_index()
          |> Enum.map(fn
            {entry, 0} ->
              Map.put(entry, "socket", Mjolnir.VirtioFS.socket_path(socket_dir, vm_id))

            {entry, _} ->
              tag = entry["tag"] || entry["id"] || "fs"
              Map.put(entry, "socket", Mjolnir.VirtioFS.socket_path(socket_dir, vm_id, tag))
          end)

        Map.put(config, "fs", remapped)

      _ ->
        config
    end
  end

  defp remap_vsock(config, vm_id, socket_dir) do
    case config["vsock"] do
      vsock when is_map(vsock) ->
        Map.put(
          config,
          "vsock",
          vsock
          |> Map.put("cid", Mjolnir.Vsock.cid(vm_id))
          |> Map.put("socket", Mjolnir.Hypervisor.CloudHypervisor.vsock_path(socket_dir, vm_id))
        )

      _ ->
        config
    end
  end

  defp remap_tap(config, vm_id) do
    case config["net"] do
      nets when is_list(nets) ->
        tap = Mjolnir.Network.tap_name(vm_id)

        remapped =
          Enum.map(nets, fn
            %{"tap" => _} = entry -> Map.put(entry, "tap", tap)
            entry -> entry
          end)

        Map.put(config, "net", remapped)

      _ ->
        config
    end
  end

  @doc """
  Copy a memory snapshot into a per-identity directory and rewrite `config.json`.

  `memory-ranges` is reflinked when the filesystem supports it (`cp --reflink=auto`),
  so two staged forks of a 2 GiB image cost ~zero extra bytes. `state.json` is
  copied whole — it is small, and restore reads it.

  ## Options

    - `:source` — snapshot memory dir (default `memory_dir(name)`)
    - `:dest` — staging dir (default `fork_dir(name, new_vm_id)`)
    - `:socket_dir` — host socket directory used in the rewrite
  """
  @spec stage_fork(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def stage_fork(name, new_vm_id, opts \\ []) do
    src = Keyword.get(opts, :source, memory_dir(name))
    dest = Keyword.get(opts, :dest, fork_dir(name, new_vm_id))
    socket_dir = Keyword.get(opts, :socket_dir, Application.get_env(:mjolnir, :socket_dir))

    cond do
      File.exists?(Path.join(dest, "config.json")) ->
        {:error, {:fork_exists, dest}}

      true ->
        with :ok <- ensure_memory_artifacts(name, src),
             :ok <- File.mkdir_p(dest),
             :ok <- copy_artifacts(src, dest),
             {:ok, config} <- read_snapshot_config(dest),
             remapped = remap_config(config, new_vm_id, socket_dir),
             :ok <- write_json(Path.join(dest, "config.json"), remapped) do
          {:ok, %{memory_dir: dest, config: remapped}}
        else
          {:error, reason} ->
            _ = File.rm_rf(dest)
            {:error, reason}
        end
    end
  end

  defp copy_artifacts(src, dest) do
    case File.ls(src) do
      {:ok, entries} ->
        Enum.reduce_while(entries, :ok, fn entry, :ok ->
          s = Path.join(src, entry)
          d = Path.join(dest, entry)

          cond do
            File.dir?(s) ->
              {:cont, :ok}

            true ->
              case copy_file(s, d) do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end
          end
        end)

      {:error, reason} ->
        {:error, {:memory_dir_unreadable, src, reason}}
    end
  end

  defp copy_file(src, dest) do
    case System.cmd("cp", ["-f", "--reflink=auto", src, dest], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        case File.cp(src, dest) do
          :ok -> :ok
          {:error, reason} -> {:error, {:copy_failed, src, dest, reason}}
        end
    end
  end

  defp write_json(path, term) do
    tmp = path <> ".tmp"

    with {:ok, body} <- Jason.encode(term),
         :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:config_write_failed, path, reason}}
    end
  end

  @doc """
  Refuse a thaw whose backends would collide with something already running.

  Two *un-remapped* thaws from one snapshot want the same virtiofsd socket
  and the same vsock CID, because both are baked into `config.json`. Without
  this check the second thaw silently attaches to the first VM's virtiofsd —
  one daemon serving two guests that each believe they own the filesystem —
  which is a data-corruption path, not a startup error.

  `thaw/3` with `remap: true` rewrites those paths first, so two remapped
  thaws of one snapshot pass this check. That is the slice that makes the
  entropy key probe runnable. Full fork (guest IP, machine-id, net_fds)
  remains `mjolnir-8m3`.

  A stale socket *file* with nothing listening is not a collision — that is the
  normal aftermath of a killed VMM — so this probes for a live listener rather
  than trusting `File.exists?/1`.
  """
  @spec preflight(map()) :: :ok | {:error, term()}
  def preflight(%{fs_socket: fs_socket} = req) do
    sockets = [fs_socket | Map.get(req, :extra_fs_sockets, [])]

    case Enum.find(sockets, &socket_live?/1) do
      nil -> :ok
      busy -> {:error, {:virtiofsd_socket_in_use, busy}}
    end
  end

  @doc """
  Whether a virtiofsd is currently serving `path`.

  ## Never connect to a vhost-user socket to test it

  The obvious implementation — connect, then close — is destructive. virtiofsd
  serves exactly one vhost-user client and **exits when that client
  disconnects** (`"Client connected, servicing requests"` →
  `"Client disconnected, shutting down"`). A probe that connects *becomes* the
  client, so closing it shuts the daemon down.

  That cost a real thaw: the probe reported the socket ready, virtiofsd exited
  immediately after, and two minutes later `vm.restore` failed with
  `vhost-user: can't connect to peer`. In `preflight/1` the same probe would
  have been aimed at a socket belonging to a **running production VM** and
  killed its filesystem daemon — a liveness check that causes the outage it is
  checking for.

  So ownership is determined from the process table instead: virtiofsd is
  launched with `--socket-path=<path>`, which is exact, non-destructive, and
  distinguishes a live daemon from the stale socket inode a killed VMM leaves
  behind.
  """
  @spec socket_live?(String.t()) :: boolean()
  def socket_live?(path) do
    case System.cmd("pgrep", ["-f", "--", "--socket-path=#{path}"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) != ""
      _ -> false
    end
  end

  @doc """
  Whether the socket *file* exists yet — a readiness check, not an ownership one.

  virtiofsd creates the socket when it is ready to accept its single client, so
  this is the correct signal to wait on before starting the VMM. It says
  nothing about who owns it; see `socket_live?/1` for that, and read its note
  on why neither of these connects.
  """
  @spec socket_present?(String.t()) :: boolean()
  def socket_present?(path) do
    case File.stat(path) do
      # A Unix domain socket is reported as :other by :file.read_file_info/1.
      {:ok, %File.Stat{type: :other}} -> true
      _ -> false
    end
  end

  @doc """
  Bring up the host-side backends a restore needs, in the only order that works.

  Hazards 2 and 5. CH **reconnects** to vhost-user backends; it does not
  respawn them, and it cannot restore into a VM that has been created or
  booted. So everything the snapshot names must already be listening before the
  VMM starts:

  1. rootfs subvolume present at the pinned generation (`prepare_thaw/2`)
  2. virtiofsd on the socket path `config.json` records — serving the **clone**,
     not the live subvolume
  3. TAP up with the name and MAC the guest's in-RAM network stack believes
  4. fresh `cloud-hypervisor`, `--api-socket`, no `--vm-config`
  5. `vm.restore`
  6. `vm.resume`, then reseed entropy before publishing reachability

  Steps 1-3 are this function; it stops before starting the VMM so a caller can
  fail without a hypervisor process to clean up. Each missing prerequisite
  fails with its own error rather than being left for CH to hang on:
  `{:virtiofsd_socket_in_use, path}`, `{:backend_socket_not_listening, path}`,
  `{:tap_setup_failed, tap, reason}`, `{:tap_name_mismatch, expected, actual}`.

  ## Options

    - `:virtiofs_start` — `(shared_dir, socket_path -> {:ok, port} | {:error, _})`
    - `:tap_create` — `(vm_id -> {:ok, net_config} | {:error, _})`
    - `:socket_timeout_ms` — how long to wait for virtiofsd to listen
      (default #{@backend_socket_timeout_ms})
  """
  @spec prepare_backends(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare_backends(prep, req, opts \\ []) do
    virtiofs_start =
      Keyword.get(opts, :virtiofs_start, &Mjolnir.VirtioFS.start/2)

    tap_create = Keyword.get(opts, :tap_create, &Mjolnir.Network.create_tap/1)
    socket_timeout = Keyword.get(opts, :socket_timeout_ms, @backend_socket_timeout_ms)

    with :ok <- preflight(req),
         # Point virtiofsd at the CLONE while keeping the socket path the
         # snapshot recorded. Decoupling those two is what lets a thaw use a
         # fresh, pinned filesystem without CH noticing the substitution —
         # proven by the manual spike, which restored onto @vms/spike3-restored
         # over the original socket path.
         {:ok, vfs_port} <- virtiofs_start.(prep.rootfs_path, req.fs_socket),
         :ok <- await_socket(req.fs_socket, socket_timeout),
         {:ok, net} <- restore_tap(req, prep, tap_create) do
      {:ok, %{virtiofsd_port: vfs_port, net: net}}
    end
  end

  # A VM frozen without networking has no TAP to recreate; that is a valid
  # snapshot, not an error.
  defp restore_tap(%{tap: nil}, _prep, _tap_create), do: {:ok, nil}

  defp restore_tap(%{tap: expected_tap} = req, prep, tap_create) do
    # Preserve (default): TAP/MAC/IP are hash-derived from the frozen VM id
    # and the guest holds those values in RAM. Remap (`thaw/3` `:remap`):
    # config.json's tap name is rewritten to the new identity so two thaws
    # do not collide; the guest MAC is kept (it is guest-visible) and is
    # therefore *not* what `Network.generate_mac(new_id)` would produce.
    tap_vm_id = Map.get(prep, :tap_vm_id) || prep.metadata[:source_vm_id]
    verify_mac? = Map.get(prep, :verify_guest_mac, true)

    cond do
      is_nil(tap_vm_id) ->
        {:error, {:snapshot_missing_source_vm_id, prep.metadata[:name]}}

      Mjolnir.Network.tap_name(tap_vm_id) != expected_tap ->
        {:error, {:tap_name_mismatch, expected_tap, Mjolnir.Network.tap_name(tap_vm_id)}}

      true ->
        case tap_create.(tap_vm_id) do
          {:ok, net} ->
            if verify_mac?, do: verify_mac(net, req, expected_tap), else: {:ok, net}

          {:error, reason} ->
            {:error, {:tap_setup_failed, expected_tap, reason}}
        end
    end
  end

  defp verify_mac(net, %{mac: expected_mac}, tap) when is_binary(expected_mac) do
    if String.downcase(net.guest_mac) == String.downcase(expected_mac) do
      {:ok, net}
    else
      # The restored guest's network stack has the old MAC in RAM. A mismatch
      # means packets leave with an address the host is not routing for.
      {:error, {:tap_mac_mismatch, tap, expected_mac, net.guest_mac}}
    end
  end

  defp verify_mac(net, _req, _tap), do: {:ok, net}

  @doc """
  Thaw a frozen VM: pinned clone → backends → fresh VMM → restore → resume.

  The whole ordering in one call. Returns
  `{:ok, %{vm_id:, api_socket:, rootfs_path:, net:, virtiofsd_port:,
  hypervisor_port:, vsock_socket:, vsock_cid:}}` — everything a caller needs to
  adopt the result as a live VM (register it, reseed it, publish it).

  **The VM is running but must not be considered reachable yet.** `vm.resume`
  has happened, so userspace is executing, but its CRNG is still whatever the
  snapshot froze — identical across every thaw of this image. The caller must
  run `Mjolnir.Entropy.reseed/2` and only then publish a PTY, a ticket, or a
  gateway route. See `Mjolnir.Entropy` for why the gate is on reachability and
  not on execution.

  On failure, everything this function started is torn back down — a
  half-thawed VM holding a virtiofsd and a TAP is worse than a clean error,
  because the sockets it holds are exactly the ones the next thaw attempt
  needs.

  ## Options

    - `:api_socket` — override the fresh VMM's API socket path
    - `:hypervisor` — module implementing `start_vm/1` (default from config)
    - `:virtiofs_start`, `:tap_create` — as `prepare_backends/3`
    - `:remap` — rewrite `config.json` onto a per-identity copy so two thaws
      of one snapshot do not collide on virtiofsd/vsock (default `false`,
      which is the proven one-at-a-time path). Required for
      `Mjolnir.Entropy.Probe`.
    - `:socket_dir` — host socket directory used when remapping
  """
  @spec thaw(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def thaw(name, new_vm_id, opts \\ []) do
    socket_dir = Keyword.get(opts, :socket_dir, Application.get_env(:mjolnir, :socket_dir))
    hypervisor = Keyword.get(opts, :hypervisor, Application.get_env(:mjolnir, :hypervisor))
    api_socket = Keyword.get(opts, :api_socket, Path.join(socket_dir, "#{new_vm_id}.sock"))
    remap? = Keyword.get(opts, :remap, false)
    opts = Keyword.put_new(opts, :socket_dir, socket_dir)

    with {:ok, prep} <- prepare_thaw(name, new_vm_id),
         {:ok, prep} <-
           discard_clone_on_error(prep, maybe_remap(prep, name, new_vm_id, remap?, opts)),
         {:ok, config} <- read_snapshot_config(prep.memory_dir),
         {:ok, req} <- required_backends(config),
         # Once the clone exists, EVERY later failure has to remove it or the
         # retry fails with :btrfs_snapshot_failed on an existing destination —
         # a confusing second error that hides the first. Found by running a
         # real thaw: virtiofsd failed to start and the leftover subvolume made
         # the next attempt fail for an unrelated-looking reason.
         {:ok, backends} <- discard_clone_on_error(prep, prepare_backends(prep, req, opts)) do
      # Only now is it safe to start a VMM: every vhost-user backend it will
      # reconnect to is listening, and the TAP it expects is up.
      case start_vmm(hypervisor, api_socket) do
        {:ok, hv_port} ->
          case do_restore(api_socket, prep, opts) do
            :ok ->
              Logger.info(
                "Thawed '#{name}' → VM #{new_vm_id} " <>
                  "(NOT yet reachable: entropy reseed still owed)"
              )

              {:ok,
               %{
                 vm_id: new_vm_id,
                 api_socket: api_socket,
                 rootfs_path: prep.rootfs_path,
                 memory_dir: prep.memory_dir,
                 net: backends.net,
                 virtiofsd_port: backends.virtiofsd_port,
                 hypervisor_port: hv_port,
                 vsock_socket: req.vsock_socket,
                 vsock_cid: req.vsock_cid,
                 fs_socket: req.fs_socket,
                 extra_fs_sockets: req.extra_fs_sockets,
                 staged: Map.get(prep, :staged, false),
                 metadata: prep.metadata
               }}

            {:error, reason} ->
              unwind(backends, req, prep, hv_port, :failed)
              {:error, reason}
          end

        {:error, reason} ->
          unwind(backends, req, prep, nil, :failed)
          {:error, {:vmm_start_failed, reason}}
      end
    end
  end

  # The clone is disposable by construction: the pinned read-only snapshot it
  # came from is untouched, so discarding it costs nothing and keeps a failed
  # thaw retryable.
  defp maybe_remap(prep, _name, _id, false, _opts), do: {:ok, prep}

  defp maybe_remap(prep, name, new_vm_id, true, opts) do
    stage_opts =
      opts
      |> Keyword.take([:dest, :socket_dir])
      |> Keyword.put(:source, prep.memory_dir)

    case stage_fork(name, new_vm_id, stage_opts) do
      {:ok, %{memory_dir: staged}} ->
        {:ok,
         prep
         |> Map.put(:memory_dir, staged)
         |> Map.put(:tap_vm_id, new_vm_id)
         |> Map.put(:verify_guest_mac, false)
         |> Map.put(:staged, true)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp discard_clone_on_error(_prep, {:ok, _} = ok), do: ok

  defp discard_clone_on_error(prep, {:error, reason}) do
    _ = BTRFS.delete_subvolume(prep.rootfs_path)
    drop_staged(prep)
    {:error, reason}
  end

  @doc """
  Tear down a successful thaw: hypervisor, virtiofsd, TAP, clone, staged fork.

  `thaw/3` already unwinds on failure. Callers that got `{:ok, thawed}` —
  including `Mjolnir.Entropy.Probe` — must call this when they are done, or
  the sockets the next thaw needs stay held.
  """
  @spec teardown(map()) :: :ok
  def teardown(thawed) when is_map(thawed) do
    req = %{
      fs_socket: Map.get(thawed, :fs_socket),
      extra_fs_sockets: Map.get(thawed, :extra_fs_sockets, [])
    }

    backends = %{
      virtiofsd_port: Map.get(thawed, :virtiofsd_port),
      net: Map.get(thawed, :net)
    }

    prep = %{
      rootfs_path: Map.get(thawed, :rootfs_path),
      memory_dir: Map.get(thawed, :memory_dir),
      staged: Map.get(thawed, :staged, false)
    }

    unwind(backends, req, prep, Map.get(thawed, :hypervisor_port), :teardown)
  end

  defp start_vmm(hypervisor, api_socket) do
    # A stale API socket from a dead VMM makes cloud-hypervisor fail to bind,
    # and the resulting error names the socket rather than the corpse.
    _ = File.rm(api_socket)

    hypervisor.start_vm(%{
      vm_id: Path.basename(api_socket, ".sock"),
      socket_path: api_socket,
      serial_path: Path.join(Path.dirname(api_socket), "#{Path.basename(api_socket)}.serial")
    })
  end

  defp do_restore(api_socket, prep, opts) do
    with :ok <- await_socket(api_socket, 10_000),
         :ok <- Client.restore_vm(api_socket, prep.memory_dir, opts),
         :ok <- Client.resume_vm(api_socket) do
      :ok
    end
  end

  # Give back every host resource this thaw claimed. The virtiofsd socket and
  # the TAP are precisely what a retry needs, so leaving them held converts one
  # failure into a permanently un-retryable one — the next attempt would hit
  # {:virtiofsd_socket_in_use, _} forever.
  defp unwind(backends, req, prep, hv_port, reason) do
    if reason == :failed do
      Logger.warning("Thaw onto #{prep.rootfs_path} failed; unwinding host resources")
    end

    if is_port(hv_port), do: safe_close(hv_port)

    if backends[:virtiofsd_port] do
      _ = Mjolnir.VirtioFS.stop(backends.virtiofsd_port)
    end

    if is_binary(req[:fs_socket]) do
      _ = Mjolnir.VirtioFS.cleanup(req.fs_socket)
    end

    if backends[:net] do
      _ = Mjolnir.Network.delete_tap(backends.net.tap_name, backends.net.guest_ip)
    end

    # The clone is disposable by construction — the pinned read-only snapshot it
    # came from is untouched — so removing it costs nothing and leaves no
    # half-thawed subvolume for a later thaw to trip over.
    if prep[:rootfs_path], do: BTRFS.delete_subvolume(prep.rootfs_path)
    drop_staged(prep)
    :ok
  end

  defp drop_staged(%{staged: true, memory_dir: dir}) when is_binary(dir) do
    # Never the original `@snapshots/<name>.mem` — only a staged fork.
    _ = File.rm_rf(dir)
    :ok
  end

  defp drop_staged(_), do: :ok

  defp safe_close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp await_socket(path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_socket(path, deadline, timeout)
  end

  defp await_socket(path, deadline, timeout) do
    cond do
      socket_present?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        # Explicitly NOT left for CH to discover. When the backend is not
        # listening, vm.restore either hangs forever or the guest wedges on
        # first I/O — both of which read as a hypervisor bug rather than a
        # missing daemon.
        {:error, {:backend_socket_not_listening, path, timeout}}

      true ->
        Process.sleep(100)
        await_socket(path, deadline, timeout)
    end
  end

  @doc """
  Whether this memory snapshot captured a suspended secrets volume.

  Reads `secrets.json` next to the CH artifacts. Missing file means the
  snapshot predates this record — treat as "unknown", not "not suspended".
  """
  @spec secrets_suspended?(String.t()) :: true | false | :unknown
  def secrets_suspended?(name) do
    path = Path.join(memory_dir(name), "secrets.json")

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"suspended" => true}} -> true
          {:ok, %{"suspended" => false}} -> false
          _ -> :unknown
        end

      {:error, :enoent} ->
        :unknown

      {:error, _} ->
        :unknown
    end
  end

  defp write_secrets_sidecar(mem_dir, info) do
    payload = Jason.encode!(%{"suspended" => Map.get(info, :suspended, false)})
    File.write(Path.join(mem_dir, "secrets.json"), payload)
  end

  defp dir_bytes(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, 0, fn entry, acc ->
          case File.stat(Path.join(dir, entry)) do
            {:ok, %{size: size}} -> acc + size
            _ -> acc
          end
        end)

      _ ->
        0
    end
  end
end
