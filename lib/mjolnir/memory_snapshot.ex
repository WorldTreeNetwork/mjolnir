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
  4. `vm.restore`
  5. Reseed guest entropy (`Mjolnir.Entropy`) — before anything can reach it
  6. `vm.resume`

  Step 5 sits before the resume deliberately; see `Mjolnir.Entropy` for why a
  thawed VM that has not been reseeded must not be reachable.

  ## Cost

  A BTRFS snapshot is effectively free (CoW). A memory snapshot is the guest's
  full RAM, uncompressed, every time — a 2 GiB VM writes 2 GiB. Memory and
  filesystem snapshots are complementary, not substitutes, and callers should
  choose deliberately.
  """

  require Logger

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
         :ok <- BTRFS.verify_generation(name),
         {:ok, %{metadata: metadata}} <- BTRFS.get_snapshot(name),
         {:ok, rootfs_path} <- BTRFS.clone_from_snapshot(name, new_vm_id, verify_generation: true) do
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
