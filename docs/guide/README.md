# Mjolnir Guide

User-facing documentation for people *using* Mjolnir — spawning, connecting to, and
snapshotting microVMs — as opposed to the architecture and design docs in the rest of `docs/`.

If you're brand new, start with the [README](../../README.md): it covers installing the `mj`
CLI, pointing it at a server, and spawning your first VM.

## Pages

Read in order if you're new:

1. **[Getting Started](getting-started.md)** — a hands-on, type-along walkthrough: spawn a
   microVM, run commands in it, disconnect and reconnect without losing work, and clean up.
2. **[Working with Snapshots](snapshots.md)** — save a VM's state and spin up new VMs from it
   instantly; fan-out, golden images, and the branch-and-recover workflow.
3. **[Coming from Docker](coming-from-docker.md)** — if you think in containers, images, and
   `docker build` layer caches, this maps those concepts onto Mjolnir's microVMs, BTRFS
   subvolumes, and copy-on-write snapshots, and explains where Mjolnir is genuinely better.
4. **[Deploying a Web App](deploying-an-app.md)** — turning an app into a live HTTPS URL: the
   release-snapshot model, how a Dockerfile maps onto it, secrets that never enter the
   artifact, gateway routing and cutover — plus an honest status table of what's shipped.

## Related (deeper) docs

- [Architecture](../architecture.md) — OTP orchestration and the module-by-module map.
- [Storage architecture *(archived)*](../archive/storage-architecture.md) — CoW, reflinks, and
  the path toward content-addressed cross-host storage. *(Archived: its ext4-image sections
  describe the retired Firecracker era; the CoW reasoning still applies.)*
- [Roadmap](../roadmap.md) — where the distributed fabric is headed.
