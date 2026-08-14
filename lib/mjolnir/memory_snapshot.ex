defmodule Mjolnir.MemorySnapshot do
  @moduledoc """
  Real freeze/thaw: guest RAM captured with the filesystem, as one artifact.

  `Mjolnir.VM.snapshot/2` is a *filesystem* snapshot. A VM "restored" from one
  is a cold boot off a snapshotted disk — every running process, open socket
  and unwritten buffer is gone. This module is the other half: it captures the
  guest's memory too, so a thawed VM resumes mid-instruction rather than
  booting.

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
  6. Reseed guest entropy (`Mjolnir.Entropy`), then publish reachability

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

  `vm` must carry `:id` and `:socket_path` (the CH API socket). The VM is
  paused for the whole capture and resumed afterwards **even if the capture
  fails** — a failed snapshot must never leave a customer's VM stopped.

  ## Options

    - `:owner_id` — recorded on the snapshot metadata
    - `:pause_fun` / `:resume_fun` — 1-arity overrides taking the API socket
      path, so a caller holding a hypervisor module can route through it
      instead of `Mjolnir.CloudHypervisor.Client` directly

  Returns `{:ok, metadata}` where metadata is the BTRFS sidecar plus
  `:memory_dir` and `:memory_bytes`.
  """
  @spec freeze(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def freeze(vm, name, opts \\ []) do
    socket = vm.socket_path
    pause = Keyword.get(opts, :pause_fun, &Client.pause_vm/1)
    resume = Keyword.get(opts, :resume_fun, &Client.resume_vm/1)
    mem_dir = memory_dir(name)

    if File.exists?(mem_dir) do
      {:error, {:snapshot_exists, name}}
    else
      case pause.(socket) do
        :ok ->
          # Everything between here and the `after` runs with no vCPU
          # scheduled. That is the entire correctness argument: the guest
          # cannot write to the filesystem between the BTRFS snapshot and the
          # RAM capture, so the two describe the same instant.
          try do
            capture(vm, name, mem_dir, opts)
          after
            case resume.(socket) do
              :ok ->
                Logger.debug("VM #{vm.id} resumed after memory snapshot")

              {:error, reason} ->
                Logger.error(
                  "VM #{vm.id} FAILED TO RESUME after memory snapshot: #{inspect(reason)} — " <>
                    "the VM is paused and needs manual intervention"
                )
            end
          end

        {:error, reason} ->
          {:error, {:pause_failed, reason}}
      end
    end
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
  Refuse a thaw whose backends would collide with something already running.

  Two thaws from one snapshot want the *same* virtiofsd socket path and the
  *same* vsock CID, because both are baked into `config.json`. Without this
  check the second thaw silently attaches to the first VM's virtiofsd — one
  daemon serving two guests that each believe they own the filesystem — which
  is a data-corruption path, not a startup error.

  So forking N VMs from one memory image is **not supported yet** and is
  refused here rather than half-working. Making it work needs per-thaw
  rewriting of `config.json` (and a CID reallocation whose interaction with the
  vsock device state in `state.json` is unproven), which is its own piece of
  work.

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
    # The guest woke believing it has a specific MAC and IP. Those are
    # hash-deterministic from the VM id, so recreating them means recreating
    # them for the vm that was FROZEN — not for the new id the clone lives
    # under. Getting this backwards yields a VM that boots fine and has no
    # working network, which is a much worse failure than refusing.
    source_vm_id = prep.metadata[:source_vm_id]

    cond do
      is_nil(source_vm_id) ->
        {:error, {:snapshot_missing_source_vm_id, prep.metadata[:name]}}

      Mjolnir.Network.tap_name(source_vm_id) != expected_tap ->
        {:error, {:tap_name_mismatch, expected_tap, Mjolnir.Network.tap_name(source_vm_id)}}

      true ->
        case tap_create.(source_vm_id) do
          {:ok, net} -> verify_mac(net, req, expected_tap)
          {:error, reason} -> {:error, {:tap_setup_failed, expected_tap, reason}}
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
  """
  @spec thaw(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def thaw(name, new_vm_id, opts \\ []) do
    socket_dir = Application.get_env(:mjolnir, :socket_dir)
    hypervisor = Keyword.get(opts, :hypervisor, Application.get_env(:mjolnir, :hypervisor))
    api_socket = Keyword.get(opts, :api_socket, Path.join(socket_dir, "#{new_vm_id}.sock"))

    with {:ok, prep} <- prepare_thaw(name, new_vm_id),
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
                 metadata: prep.metadata
               }}

            {:error, reason} ->
              unwind(backends, req, prep, hv_port)
              {:error, reason}
          end

        {:error, reason} ->
          unwind(backends, req, prep, nil)
          {:error, {:vmm_start_failed, reason}}
      end
    end
  end

  # The clone is disposable by construction: the pinned read-only snapshot it
  # came from is untouched, so discarding it costs nothing and keeps a failed
  # thaw retryable.
  defp discard_clone_on_error(_prep, {:ok, _} = ok), do: ok

  defp discard_clone_on_error(prep, {:error, reason}) do
    _ = BTRFS.delete_subvolume(prep.rootfs_path)
    {:error, reason}
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
  defp unwind(backends, req, prep, hv_port) do
    Logger.warning("Thaw onto #{prep.rootfs_path} failed; unwinding host resources")

    if is_port(hv_port), do: safe_close(hv_port)
    if backends[:virtiofsd_port], do: Mjolnir.VirtioFS.stop(backends.virtiofsd_port)
    _ = Mjolnir.VirtioFS.cleanup(req.fs_socket)

    if backends[:net] do
      _ = Mjolnir.Network.delete_tap(backends.net.tap_name, backends.net.guest_ip)
    end

    # The clone is disposable by construction — the pinned read-only snapshot it
    # came from is untouched — so removing it costs nothing and leaves no
    # half-thawed subvolume for a later thaw to trip over.
    _ = BTRFS.delete_subvolume(prep.rootfs_path)
    :ok
  end

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
