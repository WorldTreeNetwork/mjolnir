# add-deploy-build-caches

> **PENDING**

Third of four build-caching changes. Depends on `add-deploy-step-inputs`
(layer keys that stop invalidating everything) and benefits from
`add-deploy-build-sizing`.

## Why

Layers are immutable and content-addressed, so they cannot hold what
makes compilers fast: a tool's own mutable cache (`target/`,
`~/.cargo/registry`, the bun/npm store, mise installs). Any key that
includes the source misses on every change, so a Rust app recompiles all
of its crates on every deploy (identikey: 446 crates, ~45 min when the
build succeeds). A plain persistent volume would be fast but unsafe:
two builds writing one `target/` corrupt it, a failed build leaves
partial state behind, and nothing rolls back.

## What

- **Named caches**, beside layers and never inside them:
  `@caches/<owner>/<app>/<name>/current` is a read-only btrfs snapshot of
  the last good contents.
- **Checkout → mount → commit.** Each build gets an O(1) writable clone
  (`work-<build>`), mounted into the build VM at `/cache/<name>`. When
  every step succeeds, the clone is snapshotted read-only and atomically
  replaces `current`. When any step fails, the clone is deleted.
- **Correctness rule:** a build SHALL produce the same result with every
  cache empty. Caches only speed builds up; they can be evicted at any
  time and are never verified.
- **Presets from the detector**, so most apps configure nothing: Rust →
  `cargo-home` + `cargo-target`; bun/npm/pnpm → package store; mise →
  installs; apt → `/var/cache/apt/archives`. Each preset sets the tool's
  env var (e.g. `CARGO_TARGET_DIR`).
- **Manifest:** `cache = ["cargo", "bun"]`, `cache = false`, or
  `[[cache.path]] name/path` for a custom tool.
- **Hint keys (restore fallback):** a preset may name hint files (e.g.
  `Cargo.lock` + toolchain). A checkout prefers the snapshot committed
  under the same hint, else `current`, else empty.
- **Trust:** caches are scoped to `(owner, app)` and never shared across
  owners. CI and untrusted builds (Forgejo PRs) get read-only checkouts
  and never commit.
- **Operations:** `mj cache ls|rm <app> [name]` (size, last used);
  per-owner quota with least-recently-used eviction; caches unused for
  30 days are removed.

## Impact

- Capabilities: ADDED requirements in `deploy-build`
- Modules: new `Deploy.BuildCache`; `Deploy.Builder` (checkout before
  boot, commit or discard at teardown); `Deploy.Orchestrator` (mounts,
  preludes, presets); `Deploy.Manifest` (`cache`); `BTRFS` (subvolume
  snapshot/rename helpers); API + `mj cache`
- ADRs: `design.md` here (storage, concurrency, trust). Amend
  `base-images` only if an image rebuild must flush caches (it need not;
  see design).

## User journey & surfaces

The operator runs `mj deploy` as today.

- Working: progress prints `cache cargo-target: restored (current, 2.1
  GB)` before the first missed step and `committed` after success; a
  Rust source edit rebuilds only the workspace crates.
- Empty: the first deploy of an app prints `cache cargo-target: empty`
  and builds cold; it commits on success.
- Failed: a failed build prints `cache cargo-target: discarded (build
  failed)`; the previous `current` is untouched.
- Off: `cache = false` in `mjolnir.toml`; progress prints `caches: off`.
- `mj cache ls identikey` lists each cache's size and last use;
  `mj cache rm identikey cargo-target` forces the next build cold.

## Out of scope

- Artifact extraction and lean release images: `add-deploy-artifacts`.
- Sharing compiled objects across apps (an owner-wide sccache store):
  later; not tracked yet.
- Serving caches to builds on other hosts: single-host only.
- Build VM wedges (see `add-deploy-build-sizing` Out of scope).
