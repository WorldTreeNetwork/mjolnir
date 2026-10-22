# add-deploy-build-caches — design

## Two kinds of storage

| | Layers (`@snapshots/deploy-*`) | Caches (`@caches/…`) |
|---|---|---|
| Holds | outputs: packages installed, bundle, binary | tool state: `target/`, registries, stores |
| Key | content hash of inputs (exact) | `(owner, app, name)` + optional hint |
| Mutable | never | per build, via a clone |
| Correctness | the output *is* the layer | none; empty cache ⇒ same result |
| In release image | yes | no |

Putting caches in layers fails twice: a source-keyed layer misses on
every change, and whatever a layer holds ships in the service VM.

## Why clone-and-commit, not a persistent volume

- **Concurrency.** Two builds of one app each get their own clone; no
  writable directory is shared. cargo's file locks are not trusted
  across VMs over virtiofs.
- **Poisoning.** Only a fully successful build commits. A crash, OOM or
  failed step leaves `current` untouched.
- **Rollback.** Keep the previous `current` as `prev` until the next
  commit; `mj cache rm` or a quota sweep drops it.
- **Cost.** btrfs snapshots are O(1) and share extents, so a clone costs
  what it changes, the same as a volume.

Last successful commit wins. For a cache that is acceptable: it is at
worst stale, never wrong (correctness rule).

## Layout and lifecycle

```
@caches/<owner>/<app>/<name>/current         ro snapshot (last good)
@caches/<owner>/<app>/<name>/prev            ro snapshot (one back)
@caches/<owner>/<app>/<name>/hint-<sha>      ro snapshot per hint key (bounded, LRU)
@caches/<owner>/<app>/<name>/work-<build>    rw clone for one build
```

1. **Checkout** (before the build VM boots): pick `hint-<sha>` if the
   step's hint matches, else `current`, else create an empty subvolume.
   `btrfs subvolume snapshot <picked> work-<build>`.
2. **Mount**: pass each `work-<build>` as an `extra_mounts` virtiofs
   share tagged `cache-<name>`; the step prelude mounts it at
   `/cache/<name>` and exports the preset's env var.
3. **Commit** (builder teardown, success only): `snapshot -r work-<build>
   current.new`; rename `current` → `prev` (dropping the old `prev`),
   `current.new` → `current`; also write `hint-<sha>`. Then delete
   `work-<build>`. Serialize commits per cache with a host lock so two
   renames never interleave.
4. **Discard** (any failure, abort, or read-only checkout): delete
   `work-<build>`.

Orphaned `work-*` (host crash) are reaped at boot and by the quota sweep.

## Trust

- Owner and app come from the deploy's authenticated `owner_id` and app
  name, never from the manifest. A cache path is never shared across
  owners, so one tenant cannot poison another's build.
- Read-only checkouts for CI/Forgejo and any build not triggered by the
  owner's own deploy: they restore but never commit, like GitHub keeping
  PR caches away from `main`.
- Secrets are never mounted into a cache path, and the prelude refuses a
  custom `cache.path` that overlaps `/run/mjolnir`.

## Presets (detector-driven)

| Detected | Caches | Env | Hint |
|---|---|---|---|
| `Cargo.lock` | `cargo-home`, `cargo-target` | `CARGO_HOME`, `CARGO_TARGET_DIR` | `Cargo.lock`, `rust-toolchain.toml`, profile |
| `bun.lock` / npm / pnpm lockfile | `<pm>-store` | `BUN_INSTALL_CACHE_DIR` etc. | lockfile |
| mise runtime | `mise` | `MISE_DATA_DIR` | runtime spec |
| a step running `apt-get` | `apt` | bind to `/var/cache/apt/archives` | step command |

Manifest overrides: `cache = [...]` selects presets, `cache = false`
disables all, `[[cache.path]] { name, path, env? }` adds one.

## Performance gate: virtiofs or a reflinked disk

`target/` is small-file and fsync heavy. Ship over virtiofs first (it
reuses `extra_mounts`). Measure a warm identikey rebuild. If virtiofs
costs more than ~25% against a local disk, keep the same lifecycle but
store `cargo-target` as a sparse ext4 image: checkout is `cp --reflink`
(O(1) on btrfs), attached as a second virtio-blk disk. Commit and
discard are unchanged. Decide from the measurement, not now.

## Base image rebuilds

`base-images` deletes `deploy-*` layers after an in-place rebuild.
Caches need no flush: by the correctness rule a stale toolchain cache
only costs a rebuild (cargo and bun detect toolchain changes). A preset
whose hint includes the toolchain naturally starts a new `hint-*`.

## Quota and eviction

Size from btrfs qgroups per `<owner>` subtree. Over quota, evict whole
caches least-recently-used first (`hint-*`, then `prev`, then `current`).
Anything unused 30 days is removed. Eviction can slow a build, never
break it.
