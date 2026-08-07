# VM Memory Snapshot — real freeze/thaw

## Status

**Not implemented.** `Mjolnir.VM.snapshot/2` is a *filesystem* snapshot only.

`do_snapshot/3` (`lib/mjolnir/vm.ex:2317`) does:

1. `sync` in the guest (flush page cache to the virtio-fs share)
2. `pause_instance` (CH `vm.pause`) — stops vCPUs so no writes race the snapshot
3. `BTRFS.create_snapshot/3` — CoW subvolume snapshot of the rootfs
4. `resume_instance` (CH `vm.resume`) in an `after` block

Guest RAM is never captured. A "restored" VM is a **cold boot off a snapshotted disk**,
not a resumed process. Everything in memory at snapshot time — running processes, tmux
servers, open sockets, an agent's loaded context, unwritten buffers — is gone.

`Mjolnir.CloudHypervisor.Client` exposes `create/boot/pause/resume/shutdown/delete/info/resize`
and has no `snapshot` or `restore` function at all.

## Why this matters

"Checkpointable microVMs" is the product claim. Filesystem CoW is the *cloning* story;
memory snapshot is the *freezing* story, and only the second one gives you:

- Park an idle agent VM to disk and thaw it mid-thought (the DormantRegistry premise)
- Sub-second cold-start from a warmed snapshot (`mjolnir-5xn`, `mjolnir-gge`)
- Fork a live VM at a decision point
- Survive a host reboot without the guest noticing

## Spike result (2026-08-07): blocked on CH v50, fixed by CH v52

The spike ran end to end on 45.76.77.97. **Memory snapshot does not work on the deployed
stack**, and the reason is a Cloud Hypervisor version, not an architectural problem.

What works on v50.0.0:

- `vm.snapshot` succeeds (204) and writes `config.json`, `state.json`, `memory-ranges`
- A VM with **no vhost-user device** snapshots and restores perfectly: `RESTORE=204`,
  `RESUME=204`, `STATE=Running`, live `vcpu0` in `kvm_vcpu_block`

What breaks — every real Mjolnir VM, because the rootfs is virtio-fs:

| virtiofsd | Symptom |
|---|---|
| 1.10.0 (Ubuntu noble) | `vm.restore` hangs forever. CH's `vmm` thread blocks in `unix_stream_data_wait` on the vhost-user socket; no `_fs1` thread, no vcpu thread; the API call never returns |
| 1.14.0 (current upstream) | `vm.restore`/`vm.resume` return 204, CH logs `Resuming virtio-fs` / `vm resumed`, then immediately `<vcpu0> i8042 reset signalled` → `VM reset event` → `rebooting`. The guest panics on first filesystem access and `panic=1 reboot=k` cold-boots it |

**Root cause: CH v50 never transfers vhost-user backend state at all.** Evidence:

- `grep -icE 'device.state|migration|GET_DEVICE|SET_DEVICE'` over CH's `-vvv` log → **0 hits**
- The source virtiofsd logged nothing about serializing state
- `state.json`'s `_fs0` entry holds only *front-end* virtio state (`avail_features`,
  `acked_features`, config tag) — no FUSE/backend state

So the destination virtiofsd starts with an empty inode table while the restored guest
holds nodeids from the dead source instance. Hazard 1b, confirmed — it simply surfaces as
a guest panic instead of a hang once the backend (1.14) stops deadlocking. virtiofsd 1.14
is not the blocker: it implements device state correctly (`--migration-mode`,
`src/passthrough/device_state/*`), CH just never asks.

**The fix is a version bump, not a virtio-blk fork.** Cloud Hypervisor
[v52.0](https://github.com/cloud-hypervisor/cloud-hypervisor/releases/tag/v52.0)
(2025-05-14) resolves this and three other hazards below:

- *"Snapshot/restore support for `vhost-user` devices has been filled out (#7908),
  including migration support for `virtio-fs` (#7937)"* → hazard 1b
- *"Vsock connections are now reset on snapshot restore to avoid stale half-open
  connections on the guest side (#7958)"* → hazard 4
- *"The KVM clock is now restored before vCPUs are resumed (#7932)"* → hazard 6
- New `memory_restore_mode` populates guest memory lazily via `userfaultfd` instead of
  reading the whole snapshot before resume → restore latency

Upstream issue
[#6931](https://github.com/cloud-hypervisor/cloud-hypervisor/issues/6931), "Unable to
restore a snapshot of vm using virtiofs root", is the same hang and is closed.

Tracked as `mjolnir-3y6.15`; everything else in the epic is gated behind it.

### Also found: a long pause wedges the VM permanently (`mjolnir-8ie`)

Independent of restore. A pause long enough to write RAM to disk severs the host↔guest-agent
vsock; the agent does not re-establish on resume; the next `exec` hits
`vm.ex:2161` `Connection.exec(..., :infinity)` and blocks the VM GenServer mailbox forever.
Health.Monitor then logs `GenServer unreachable (call timed out)` every tick and never
recovers, because every heal path goes through that same GenServer.

`mjolnir-8ie` was filed in June with no reliable reproduction; this is one. Of the recovery
endpoints, only `POST /vms/:id/reboot` works (it kills CH at the OS level, bypassing the
mailbox) — `nuke`, `retire`, and `forget` all return `vm_unreachable`. Since the freeze
pause window is inherently long, this must be fixed before freeze/thaw can work at all.

## CH protocol

Snapshot (VM must be paused first):

```
PUT /api/v1/vm.pause
PUT /api/v1/vm.snapshot   {"destination_url": "file:///<dir>"}
```

Writes `config.json`, `state.json`, and memory range files into `<dir>`.

Restore requires a **fresh VMM process** — you cannot restore into a booted VM:

```
cloud-hypervisor --api-socket <new.sock>          # do NOT --vm-config
PUT /api/v1/vm.restore    {"source_url": "file:///<dir>", "prefault": false}
PUT /api/v1/vm.resume
```

## The seven hazards

Ordered by how badly they bite.

### 1. Disk/memory atomicity — the correctness keystone

Guest RAM holds a page cache that believes in a specific on-disk state. If the btrfs
subvolume snapshot and the CH memory snapshot are taken at different moments — or if the
subvolume is written after the memory snapshot — you resume a kernel whose cached inodes
disagree with the filesystem. That is silent corruption, not a crash.

**Flushing is not the fix.** `do_snapshot/3` already runs `sync` in the guest, but `sync`
only writes back *dirty* pages. The hazard is *clean* cached pages: the guest keeps them
and has no reason to re-read, so they go stale the moment the disk moves underneath.
`drop_caches` doesn't close it either — it cannot evict pages that are mmap'd or in
active use (every running binary's text pages, every mmap'd file), and it trades a
correctness hole for a cold-cache performance cliff. It is a mitigation, not a guarantee.

**The fix is immutability, not flushing.** A stale cache is only *wrong* if the disk
changed. If restore always presents a filesystem byte-identical to what the guest saw at
snapshot time, every cached page is correct by construction and cache state stops being
something anyone has to reason about.

Concretely: restore must never point virtiofsd at the live `@vms/<uuid>/` subvolume —
which is exactly what it does today (`--shared-dir=/var/lib/mjolnir/btrfs/@vms/<uuid>`).
It must point at a fresh CoW clone of the `@snapshots/<name>/` subvolume captured in the
same pause window. The memory image and the filesystem snapshot are one indivisible
artifact; store the btrfs subvolume generation (`btrfs subvolume show`) in the metadata
and refuse to restore a mismatch.

### 1b. virtiofsd nodeid stability — the likely spike-killer

Sharper than the page cache, and specific to virtio-fs: the guest does not cache "blocks
of a disk". It holds FUSE-level state — inode IDs (nodeids) and file handles that
*virtiofsd assigned* — and that state lives in guest RAM.

On restore a **fresh virtiofsd process** starts assigning nodeids from scratch, while the
restored guest holds the previous process's numbering. Unless that mapping is preserved or
deterministic, every open file in the guest refers to the wrong inode or to nothing.

CH's `Restoring vhost-user-fs` restores *CH's* device state (virtqueues, config space).
virtiofsd is a separate process whose state is **not** in the CH snapshot. Whether v50 +
our virtiofsd preserve nodeids across a restore is unknown and is the single most likely
reason the spike fails.

If it does not hold, the options are:

- a virtiofsd supporting vhost-user backend state transfer
  (`VHOST_USER_PROTOCOL_F_DEVICE_STATE`), or
- a rootfs on **virtio-blk** (a block image on btrfs) for freezable VMs, which is a
  significant architecture fork from the current virtio-fs design.

Determine this first. It gates the shape of everything else.

### 2. virtiofsd lifecycle

The rootfs arrives over vhost-user from a *separate host process*. CH's restore
reconnects to a vhost-user socket; it does not respawn the daemon. So restore ordering is:

1. Recreate/locate the rootfs subvolume at the pinned generation
2. Start `virtiofsd` on the **same socket path** the snapshot recorded
3. Start the new CH process
4. `vm.restore`

If virtiofsd isn't listening, restore fails or the guest wedges on first I/O.

### 3. Entropy reuse — security

Restoring one memory snapshot twice yields two VMs with **identical RNG state**. They will
generate the same session keys, the same TLS nonces, the same UUIDs. This is the classic
VM-snapshot cloning vulnerability and it is a real key-compromise path, not a theoretical
one. Note the asymmetry: thawing a snapshot *once* and discarding it is far less exposed
than *forking* N VMs from one image — and forking is a feature we want, so this cannot be
deferred as an edge case.

**The correct mechanism is VMGENID.** An ACPI device holding a 128-bit generation ID that
the hypervisor changes on restore. Linux's `drivers/virt/vmgenid.c` (5.18+) notices the
change and reseeds the CRNG **in the kernel, before userspace is scheduled** — which is
precisely the non-racy property required, and which no userspace reseed can provide.

Neither half is available today (checked against the deployment, 2026-08-07):

- `cloud-hypervisor v50.0.0` — no VMGENID strings in the binary; not implemented
- `/var/lib/mjolnir/vmlinux-ch` — no `vmgenid` / `VM_GEN_COUNTER` symbols; driver not built in
- The CH config has **no virtio-rng device at all** (`Mjolnir.CloudHypervisor.Config` never
  emits one), though the guest kernel does carry the `virtio_rng` driver

So the target is: enable `CONFIG_VMGENID` in our PVH kernel (cheap — we already build it)
and add the ACPI device to CH (an upstream contribution or a patched build).

Until then, a layered interim — honest about its limits:

1. **Add a virtio-rng device.** Missing entirely today, and a prerequisite for everything
   else. Note it does not by itself force a reseed; it only makes entropy available.
2. **Guest-agent reseed via `RNDADDENTROPY`** on `/dev/random`, with fresh bytes supplied
   by the host over vsock. Use the ioctl, not a write to `/dev/urandom`: a plain write
   mixes into the pool but does **not** credit the entropy count.
3. **Gate reachability on the host** to shrink the race. vCPUs all resume at once, so the
   agent cannot beat userspace — but the host can hold the VM unreachable (no PTY, no
   ticket, no network attach) until the agent confirms reseed. Exposure narrows to
   processes already inside that autonomously generate keys in the first milliseconds,
   rather than anything an outside caller can induce.

The residual race in (2)/(3) is unavoidable without VMGENID. That is the argument for
doing VMGENID properly rather than treating the interim as the destination.

### 4. vsock reconnect

The guest agent holds a live vsock connection in restored RAM and believes it is
connected. The host-side `Mjolnir.Vsock.Connection` GenServer for the old VM is gone.
The CID must be preserved (it is derived from the VM UUID, so it is stable), but both
ends need to renegotiate. Needs an explicit post-restore handshake and a guest-agent
path that detects a dead peer and re-listens rather than hanging.

### 5. Network identity

TAP device, MAC, and IP must be recreated *before* restore and must match exactly what
the guest's in-RAM network stack believes. `Mjolnir.Network` allocation is
hash-deterministic from the VM id, which helps — but the TAP must exist and be up first,
and any host-side NAT/route entries must be re-established.

### 6. Clock jump

The guest wakes believing it is snapshot-time. Certificate validity, agent timeouts,
cron, and log timestamps all skew by the freeze duration. Needs a KVM-clock adjust or a
guest-agent time-sync step on resume, before userspace continues.

### 7. Iroh liveness

The guest's Iroh node has live QUIC connections in restored RAM that are now dead. The
node ID is stable, so tickets survive, but the failure mode is nasty: the VM reports
healthy while nothing can actually reach it. Post-restore health must probe Iroh
reachability, not just guest-agent ping.

## Cost note

A btrfs snapshot is ~free (CoW). A memory snapshot is the full RAM, uncompressed:
**measured in the spike, a 1 GiB VM produced a `memory-ranges` file of exactly
1073741824 bytes**, with the snapshot directory totalling 1.1G. Snapshot storage needs
compression (zstd on the btrfs subvolume holding memory ranges) and a retention policy,
or a busy host fills up. v52's `memory_restore_mode` helps restore *latency*, not on-disk
*size*. This changes the economics of "snapshot everything": memory and filesystem
snapshots are complementary, not substitutes, and callers should choose deliberately.

## Sequencing

Prove the mechanism before wiring it into the product surface: a paused VM captured and
resumed by hand, with a process that survives the freeze, is the gate. Only then
integrate with DormantRegistry, `mj snapshot`, and the deploy/CI warm-start paths.

Filesystem snapshot stays as its own operation. Memory snapshot is a strictly heavier,
strictly more capable sibling — callers should choose.
