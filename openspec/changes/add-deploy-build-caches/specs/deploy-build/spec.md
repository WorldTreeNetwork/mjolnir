## ADDED Requirements

### Requirement: Build caches never decide a build's output

A deploy build SHALL produce an equivalent release whether its caches
are empty or warm: the same files, built from the same source, passing
the same smoke check. Byte identity is not required, because not every
toolchain builds reproducibly. Caches SHALL live under
`@caches/<owner>/<app>/<name>/` and SHALL NOT be part of any
`deploy-*` layer or release snapshot.

#### Scenario: Cold and warm builds agree

- GIVEN an app built once with warm caches
- WHEN its caches are removed and the same source is deployed
- THEN the release has the same file list
- AND the service passes the same smoke check

### Requirement: Each build uses a private clone committed only on success

Before the build VM boots, the builder SHALL clone each of the app's
caches from its hint snapshot, else `current`, else an empty subvolume,
into a writable `work-<build>` subvolume, and mount it at
`/cache/<name>`. If every step succeeds, the builder SHALL snapshot the
clone read-only and atomically make it `current`, keeping the previous
one as `prev`. If any step fails, the build aborts, or the checkout is
read-only, the builder SHALL delete the clone and leave `current`
unchanged. Two builds SHALL never share a writable cache directory.

#### Scenario: Failed build does not poison the cache

- GIVEN `current` for `cargo-target`
- WHEN a build fails at its last step
- THEN `current` is unchanged
- AND the build's `work-*` clone is gone

#### Scenario: Concurrent builds

- GIVEN two deploys of one app start together
- WHEN both build
- THEN each mounts its own clone
- AND `current` ends as the clone of whichever succeeded last

#### Scenario: First build of an app

- GIVEN no cache exists for the app
- WHEN it deploys and succeeds
- THEN progress reports the cache as empty, then committed

### Requirement: Caches are scoped to an owner and an app

Cache paths SHALL be derived from the deploy's authenticated owner and
app name, never from the manifest. Builds not started by the owner's own
deploy (CI, Forgejo pull requests) SHALL receive read-only checkouts and
SHALL NOT commit.

#### Scenario: Another owner cannot reach a cache

- GIVEN owner A has a `cargo-target` cache for app `api`
- WHEN owner B deploys an app also named `api`
- THEN B's build receives B's own cache or an empty one, never A's

#### Scenario: PR build reads but does not write

- GIVEN a Forgejo pull-request build of an app with a warm cache
- WHEN it succeeds
- THEN it restored the cache
- AND `current` is unchanged

### Requirement: Caches are chosen by detection, configured only to override

The builder SHALL attach caches by detector preset (Rust → `cargo-home`,
`cargo-target`; bun/npm/pnpm → package store; mise → installs; apt steps
→ package archives) and export each preset's environment variable. A
manifest SHALL be able to select presets (`cache = [...]`), disable all
(`cache = false`), or add a path (`[[cache.path]]`). A cache path
overlapping `/run/mjolnir` SHALL be refused.

#### Scenario: Rust app with no cache config

- GIVEN an app with `Cargo.lock` and no `cache` key
- WHEN it deploys
- THEN `/cache/cargo-target` is mounted and `CARGO_TARGET_DIR` points at it

#### Scenario: Caches off

- GIVEN `cache = false`
- WHEN the app deploys
- THEN no cache is mounted and progress says caches are off

### Requirement: Operators can inspect and evict caches

`mj cache ls <app>` SHALL list each cache with size and last use.
`mj cache rm <app> [name]` SHALL delete it. The host SHALL enforce a
per-owner quota by evicting least-recently-used caches and SHALL remove
caches unused for 30 days.

#### Scenario: Forced cold build

- GIVEN a warm `cargo-target` cache
- WHEN the operator runs `mj cache rm identikey cargo-target` and deploys
- THEN the build restores an empty cache and commits a new one
