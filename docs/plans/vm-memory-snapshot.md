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

## It is achievable

Verified against the deployed hypervisor on 45.76.77.97:

- `cloud-hypervisor v50.0.0`, features `io_uring, kvm, mshv`
- Binary exports `vm.snapshot`, `vm.restore` (alongside `vm.pause` / `vm.resume`)
- Binary contains `Restoring vhost-user-fs` — **virtio-fs restore is supported in v50**,
  which was the blocker in older CH releases and the main risk to this design

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

Both snapshots must be taken inside a single pause window, and the restore must be
pinned to the exact subvolume generation the memory snapshot was taken against.
Store the btrfs subvolume generation (`btrfs subvolume show`) in the snapshot metadata
and refuse to restore a mismatch.

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
VM-snapshot cloning vulnerability and it is a real key-compromise path, not a theoretical one.

Mitigation: reseed at resume — virtio-rng plus an explicit guest-agent
`reseed` op writing fresh entropy to `/dev/urandom` before any userspace unfreezes.
Applies to *every* restore, including the first.

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

A btrfs snapshot is ~free (CoW). A memory snapshot of a 2GB VM is 2GB on disk, every
time. Snapshot storage needs compression (zstd on the btrfs subvolume holding memory
ranges) and a retention policy, or a busy host fills up. This changes the economics of
"snapshot everything" and should inform where memory snapshots are used vs. plain
filesystem snapshots — they are complementary, not a replacement.

## Sequencing

Prove the mechanism before wiring it into the product surface: a paused VM captured and
resumed by hand, with a process that survives the freeze, is the gate. Only then
integrate with DormantRegistry, `mj snapshot`, and the deploy/CI warm-start paths.

Filesystem snapshot stays as its own operation. Memory snapshot is a strictly heavier,
strictly more capable sibling — callers should choose.
