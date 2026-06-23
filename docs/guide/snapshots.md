# Working with Snapshots

A snapshot is a **frozen, reusable copy of a VM's entire disk state** that you can spin up new
VMs from — instantly, as many as you want. This is Mjolnir's superpower: build an environment
once, then summon fresh, independent copies of it in milliseconds.

This guide assumes you've done the [Getting Started](getting-started.md) walkthrough and have a
running VM.

> **The mental model in one line:** a snapshot is a saved game. You play (run a VM), save
> (snapshot), and later load that save into one — or a hundred — brand-new machines, each free
> to diverge without affecting the save or each other.

---

## Why snapshots, not just long-lived VMs?

You *could* keep one VM running forever and treat it as your environment. Snapshots are better:

- **Disposable VMs, durable state.** Kill a VM whenever; the snapshot is the thing that lasts.
- **Fan-out.** Spawn 50 identical environments from one snapshot for the cost of one (see
  [the storage story](coming-from-docker.md#the-storage-primitives-explained-for-a-docker-user)).
- **Branching.** Snapshot before a risky change. If it goes wrong, spawn a fresh VM from the
  snapshot and you're back to a known-good state — no "undo," just a clean clone.
- **Golden images.** Provision your toolchain once, snapshot it as `dev-env`, and every future
  VM starts pre-loaded.

---

## 1. Build something worth saving

Spawn a VM and set it up the way you want. We'll make a Node.js dev environment:

```bash
mj spawn --connect
```

Inside the VM:

```bash
apt-get update && apt-get install -y nodejs npm
npm install -g pnpm
node --version          # confirm it's there
exit                    # leave the shell; the VM keeps running
```

Find the VM's ID:

```bash
mj list
# a1b2c3d4-...   running   512 MB
```

---

## 2. Snapshot the running VM

Freeze its current state under a name you'll remember:

```bash
mj snapshot a1b2c3d4-... node-env
```

```
Created snapshot 'node-env'
```

That's it. `node-env` is now a saved state. Behind the scenes Mjolnir quiesced the filesystem
for a consistent capture (flush the guest, pause it, fsync the host, take a
`btrfs subvolume snapshot`, resume) — so the snapshot is crash-consistent, not a smear of
half-written files. The capture itself is a ~1ms copy-on-write metadata operation regardless of
how big the filesystem is.

> **`--compact`:** add it (`mj snapshot <id> <name> --compact`) to reclaim blocks that were
> freed inside the guest before snapshotting, producing a tighter snapshot. Skip it for speed.

---

## 3. List your snapshots

```bash
mj snapshots
```

```
NAME        SOURCE VM        CREATED               SIZE
node-env    a1b2c3d4-...     2026-06-22T22:10:00Z  412 MB
```

The size shown is the snapshot's referenced data; because of copy-on-write block sharing, the
*actual extra disk* it costs on top of its base is typically far smaller.

---

## 4. Spin up a VM from the saved state

This is the payoff. Create a brand-new VM that starts exactly where `node-env` left off:

```bash
mj spawn --snapshot node-env --connect
```

You're dropped into a fresh VM — and `node`, `npm`, and `pnpm` are already installed, because
this machine *began life* as a clone of your snapshot. You didn't reinstall anything; the clone
was instant.

```bash
node --version          # already here
pnpm --version          # already here
```

This new VM is **fully independent**. Anything you change here does not affect `node-env` (the
snapshot is immutable — never written to, only cloned from) or any other VM spawned from it.

---

## 5. Fan out: many machines from one save

Because each clone is instant copy-on-write, spinning up a fleet is cheap in both time and disk:

```bash
# Five independent dev boxes, all pre-loaded with your node-env toolchain
for i in $(seq 1 5); do
  mj spawn --snapshot node-env
done

mj list     # five running VMs, each sharing node-env's blocks until it diverges
```

Fifty VMs from a 5 GB snapshot don't cost 250 GB — they cost ~5 GB plus whatever each one
*changes*. Each is a real, isolated machine.

---

## 6. The "branch and recover" workflow

Snapshots make experimentation safe:

```bash
# 1. You have a working VM. Snapshot it as a safety net.
mj snapshot a1b2c3d4-... before-upgrade

# 2. Try something risky in the VM (a major upgrade, a config rewrite)...
mj exec a1b2c3d4-... "apt-get -y full-upgrade && reboot-into-the-unknown"

# 3a. It worked → snapshot the new good state.
mj snapshot a1b2c3d4-... after-upgrade

# 3b. It broke → throw the VM away and spawn a clean one from the safety net.
mj kill a1b2c3d4-...
mj spawn --snapshot before-upgrade --connect
```

There's no in-place rollback — and you don't need one. Recovery *is* spawning a fresh clone
from a known-good snapshot.

---

## 7. Each clone gets its own identity

When you spawn from a snapshot, Mjolnir gives the new VM a **fresh network identity** (a new
Iroh node key) rather than letting it inherit the snapshot's. So 50 VMs from one snapshot are 50
distinct peers with 50 distinct tickets — they won't collide on the network even though their
disks started identical.

---

## 8. Deleting snapshots

Delete a snapshot with `mj snapshot rm`:

```bash
mj snapshot rm node-env

# Or directly against the API:
#   DELETE /api/snapshots/node-env
```

Deleting a snapshot is safe even if VMs are still running from it — copy-on-write means those
VMs already hold their own references to the shared blocks; the data they need won't vanish.

---

## Snapshot command cheat sheet

| Goal | Command |
|---|---|
| Snapshot a running VM | `mj snapshot <vm_id> <name>` |
| Snapshot + reclaim freed space | `mj snapshot <vm_id> <name> --compact` |
| List snapshots | `mj snapshots` |
| Spawn a VM from a snapshot | `mj spawn --snapshot <name>` |
| Spawn from a snapshot + connect | `mj spawn --snapshot <name> --connect` |
| Delete a snapshot | `mj snapshot rm <name>` |

---

## Next steps

- **[Getting Started](getting-started.md)** — the basics, if you skipped them.
- **[Coming from Docker](coming-from-docker.md)** — why "instant clone of any size" is a
  property of the storage design, and how this compares to Docker's layer cache.
- [README](../../README.md) — full CLI reference and the `just` control plane.
