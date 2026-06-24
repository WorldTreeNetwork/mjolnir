# Coming from Docker

If you reach for `docker run` when you need a clean, disposable Linux environment, Mjolnir
will feel familiar — and then, in a few specific places, much better. This page maps Docker
concepts onto Mjolnir, explains the storage primitives (BTRFS, reflinks, copy-on-write) that
make it tick, and is honest about where Mjolnir is genuinely superior versus where it's just
*different*.

> **TL;DR** — A container is a process wearing a costume. A Mjolnir VM is a real machine you
> can freeze mid-thought and clone in a millisecond. Docker's layer cache made `docker build`
> feel instant on rebuild; Mjolnir's BTRFS snapshots are that same idea applied to a *running
> operating system with live state*, not just a stack of read-only image layers.

---

## The one-paragraph mental model

Docker gives you an **image** (a layered, read-only tarball of a filesystem) and a
**container** (a Linux process tree sharing the host kernel, fenced off with namespaces and
cgroups). Mjolnir gives you a **base subvolume** (a real on-disk Linux filesystem) and a
**microVM** (a genuine guest kernel running under hardware virtualization, KVM). The container
borrows the host's kernel; the microVM brings its own. That single difference — *real machine,
not a costumed process* — is what makes everything below possible: you can checkpoint the whole
machine, clone it while it's running, and hand someone a peer-to-peer connection into it.

---

## Concept translation table

| Docker | Mjolnir | What's actually different |
|---|---|---|
| `docker run alpine` | `mj spawn` | Mjolnir boots a real microVM (own kernel, KVM-isolated) in well under a second, not a namespaced process. |
| Image (`alpine:3.20`) | Base subvolume (`@base/ubuntu-24.04`) | A real BTRFS filesystem tree, not a stack of read-only tar layers. |
| `docker exec -it … sh` | `mj exec` / `mj connect` | `connect` gives you a true PTY over WebSocket **or** Iroh QUIC (P2P, NAT-traversing). |
| `docker commit` | `mj snapshot <vm> <name>` | Snapshots a **running** machine's full disk state, not just a stopped container's writable layer. |
| `docker run my-commit` | `mj spawn --snapshot <name>` | Restores from a snapshot via an instant CoW clone. A snapshot *is* a spawnable base. |
| Image layer cache | BTRFS subvolume snapshots | CoW at the *filesystem* level, applied to live machine state — see below. |
| `docker rm -f` | `mj kill <vm>` | Stops the microVM and deletes its CoW subvolume. |
| Dockerfile | (no equivalent yet) | Mjolnir has the *primitives* a build cache is made of, but no declarative build file. See "The build-cache vision." |
| `docker ps` | `mj list` | — |
| Docker registry / `push` | Iroh content-addressed transfer (emerging) | Cross-host movement is by content-addressed sync, not a central registry. See `docs/archive/storage-architecture.md` §3. |
| Container = ephemeral, stateless by convention | VM = checkpointable, stateful by design | State is a feature, not something you engineer around with volumes. |

> The CLI is `mj` (also installed as `mjolnir`). See the [README](../../README.md#use-it) for
> install and the full command surface.

---

## The storage primitives, explained for a Docker user

You already understand the most important idea — you've watched it work every time
`docker build` skipped six unchanged steps. The difference is *where* the copy-on-write
happens and *what* it can copy.

### Copy-on-write (CoW), the thing under both

Docker's overlayfs and Mjolnir's BTRFS are both **copy-on-write** systems. The promise of CoW
is simple: *sharing is free until you change something.* Two things can point at the exact same
bytes on disk, costing nothing extra, right up until one of them writes — at which point only
the changed block is duplicated. Everything unchanged stays shared.

Docker implements this with **overlayfs**: a union mount that stacks read-only image layers
under a thin writable layer. It works, but it's a filesystem *trick layered on top of* whatever
your real filesystem is, and it operates in terms of opaque tar layers.

Mjolnir implements it with **BTRFS subvolumes**, where CoW is the native, first-class behavior
of the filesystem itself — no union-mount machinery, no layer stack to flatten.

### Subvolumes and snapshots

A **BTRFS subvolume** is an independently-snapshottable filesystem tree. Mjolnir's storage
layout is three directories of them:

```
/var/lib/mjolnir/btrfs/
├── @base/
│   └── ubuntu-24.04/        ← a base subvolume (the "image")
├── @vms/
│   └── <uuid>/              ← a per-VM clone (the running rootfs)
└── @snapshots/
    ├── my-node-env/         ← a named snapshot (a frozen, spawnable rootfs)
    └── my-node-env.json     ← its metadata sidecar
```

Spawning a VM is one BTRFS operation:

```
btrfs subvolume snapshot  @base/ubuntu-24.04  @vms/<uuid>
```

This is the line in `lib/mjolnir/btrfs.ex` that makes Mjolnir feel like magic. It is a
**metadata-only operation**: it creates a new subvolume that *shares every block* with the base
and diverges only where the new VM writes. It completes in roughly a millisecond **regardless
of how big the filesystem is** — a 200 MB Alpine base and a 20 GB data-science base clone in the
same near-zero time, because nothing is actually copied. The guest then mounts this subvolume
directly via **virtio-fs**; there is no disk-image blob in between (Mjolnir used to use ext4
images in the Firecracker era — that's gone).

> **Reflinks vs. subvolume snapshots — a note on vocabulary.** You'll see "reflink" used a lot
> around Mjolnir, and it's the right word for the *idea*: a reference-counted, copy-on-write
> clone that shares blocks until written. At the file level, `cp --reflink` clones a single
> file that way. Mjolnir clones whole filesystem *trees*, so the actual primitive is
> `btrfs subvolume snapshot` — same CoW physics, applied to a subvolume instead of one file.
> When someone says "reflink-clone the snapshot," that's the operation they mean.

### Why "instant clone of any size" is the headline

In Docker, pulling or building a large image is real I/O — gigabytes get written to disk. A
"clone" of a big environment is expensive. In Mjolnir, because the clone is reference-counted
CoW at the filesystem layer, **size is free**. Fifty VMs spawned from the same 5 GB snapshot
don't cost 250 GB; they cost 5 GB plus whatever each one *changes*. You can fan out a hundred
identical environments for the cost of one, and each is fully independent — a write in VM 3 is
invisible to VM 4 and to the snapshot they both came from.

---

## Where Mjolnir is genuinely *better*

These aren't matters of taste. They're capabilities a container model structurally can't offer.

1. **You can snapshot a *running* machine, not just a stopped filesystem.**
   `docker commit` captures a container's writable layer — the files. Mjolnir's snapshot
   captures the live rootfs of a VM that's actually running, quiesced for consistency (guest
   `sync` → pause → host fsync → CoW clone → resume). A snapshot is a *restore point for a whole
   machine*, and you can spawn an army of independent clones from it.

2. **Real isolation, real kernel.** A container shares the host kernel; a kernel bug or a
   container-escape is a host compromise. A Mjolnir microVM runs its own kernel behind the same
   KVM boundary that isolates cloud tenants from each other. This is why it's safe to hand an AI
   agent *full root* inside a Mjolnir VM in a way that's genuinely uncomfortable inside a
   container.

3. **The clone is the cache, and the cache is the machine.** Docker's build cache is a
   stack of read-only layers you assemble *into* a container. Mjolnir's "cache" is a snapshot
   that you boot *as* a machine — same artifact, no flattening step, and it carries live state,
   not just files.

4. **Peer-to-peer access is built in.** `mj connect` and `mj ssh` reach into a VM over
   [Iroh](https://iroh.computer) QUIC — NAT-traversing, no port-forwarding, no public IP, no
   reverse proxy. Getting an interactive shell into a container behind two NATs is a
   you-problem in Docker; in Mjolnir it's a ticket string.

5. **State is a first-class citizen.** The whole design assumes you *want* to freeze, clone,
   migrate, and resume machines with their state intact. In Docker you're taught to be
   stateless and push all state into volumes and external stores — fighting the model. Mjolnir
   leans into it.

---

## Where it's just *different* (set expectations)

Honesty keeps this useful:

- **It's a VM, so it needs Linux + KVM on the host.** The Mjolnir *server* must be a Linux box
  with hardware virtualization. The `mj` CLI runs fine from a Mac, but the VMs live on the
  server. (Containers, by contrast, run anywhere a container runtime does.)
- **No Dockerfile.** There is no declarative build format today. You build an environment by
  spawning, `exec`-ing your setup, and snapshotting — imperatively. See the next section for
  where this is headed.
- **No registry ecosystem.** There's no Docker Hub to `pull` from. Base images are built on the
  server; cross-host movement uses content-addressed sync, which is still emerging
  (`docs/archive/storage-architecture.md` §3 covers the trajectory).
- **Single node, today.** VMs run on one host. Distributed scheduling across a fabric is a
  roadmap item (`docs/roadmap.md`), not a shipped feature.
- **Boot is fast, but not zero.** A microVM boots its own kernel — well under a second, but it
  *is* a boot, not the near-instantaneous `fork` of a container process.

---

## The build-cache vision (what these primitives compose into)

Here's the part worth getting excited about, stated plainly as a *design direction* rather than
a shipped feature.

Docker's layer cache is what made iterative `docker build` bearable: change line 12 of your
Dockerfile, and only steps 12-onward re-run; steps 1–11 are reused from cache. But that cache is
overlayfs machinery over read-only tar layers, and the thing you get at the end is a *container*.

Mjolnir's snapshot primitive is a strictly more powerful version of exactly that idea. Imagine a
build expressed as steps, where after each step you snapshot the machine and content-address the
inputs to the next:

```
step 1  apt install …     → snapshot s1   (keyed by the step's content hash)
step 2  pip install …     → snapshot s2
step 3  copy app code     → snapshot s3
step 4  warm caches       → snapshot s4
```

On a rebuild where step 3 changed but 1–2 didn't, you **reflink-clone snapshot s2** (instant,
metadata-only) and resume the build at step 3 — skipping the unchanged prefix exactly the way
Docker skips cached layers. The differences that make it *better*:

- The cache hit is a **live, bootable machine**, not a read-only layer you still have to
  assemble and start. You can boot s2, poke at it, and continue.
- It carries **runtime state**, not just files — warmed caches, started services, primed
  databases survive the snapshot.
- The clone is **size-independent CoW**, so caching a 20 GB environment costs the same as
  caching a 200 MB one.

**Status:** the primitives this is built from — instant CoW clone, snapshot-of-running-machine,
spawn-from-snapshot — all work today and are exactly what `mj snapshot` / `mj spawn --snapshot`
expose. The declarative pipeline that orchestrates them into a content-addressed build cache is
a design direction, not a shipped `mj build`. The foundation is real; the bow on top is roadmap.

---

## A worked example: build an environment, then fan out

This uses only shipped commands.

```bash
# 1. Spawn a fresh microVM; `mj spawn` prints its Iroh connection ticket to stdout
ticket=$(mj spawn)

# 2. Provision it imperatively (this is your "Dockerfile," run live).
#    exec accepts a VM ID *or* a ticket.
mj exec "$ticket" "apt-get update && apt-get install -y nodejs npm"
mj exec "$ticket" "npm install -g pnpm"

# 3. Freeze the result as a reusable, spawnable base
mj snapshot "$ticket" node-env

# 4. Fan out: ten independent dev boxes, instantly, sharing one rootfs on disk
for i in $(seq 1 10); do
  mj spawn --snapshot node-env
done
```

Each of those ten VMs is a full, independent Linux machine that booted in well under a second
and, on disk, costs almost nothing until it diverges from `node-env`. Try the equivalent fan-out
of ten *stateful* container commits and feel the difference.

---

## Quick FAQ

**Is this slower than Docker?** Boot is slightly slower (a real kernel boots), clone and
snapshot are dramatically faster (CoW metadata vs. layer I/O), and isolation is much stronger.

**Can I run my existing Docker images?** Not directly — Mjolnir boots full VM rootfs subvolumes,
not OCI images. You provision a base and snapshot it (see the worked example). OCI-image import
isn't a feature today.

**Do I lose my data when a VM stops?** `mj kill` deletes the VM's CoW subvolume. To keep state,
`mj snapshot` first — that's the entire point of the snapshot primitive.

**Why BTRFS specifically?** Native, first-class copy-on-write at the filesystem level, plus
subvolume snapshots and `virtio-fs` direct sharing into the guest. It's the substrate that
makes "instant clone of any size" a property of the system rather than a feature you bolt on.

---

## Where to go next

- [README → Use it](../../README.md#use-it) — install `mj` and spawn your first VM.
- [Architecture](../architecture.md) — the OTP orchestration and module map.
- [`docs/archive/storage-architecture.md`](../archive/storage-architecture.md) — deep dive on
  CoW, reflinks, and the content-addressed-storage trajectory. *(Archived: its ext4-image
  sections describe the retired Firecracker era; the CoW reasoning and the Phase 3/4 vision
  still apply.)*
- [Roadmap](../roadmap.md) — where the distributed fabric is headed.
