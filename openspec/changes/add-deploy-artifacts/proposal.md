# add-deploy-artifacts

> **PENDING**

Fourth of four build-caching changes. Depends on
`add-deploy-build-caches`: once `target/` lives in `/cache/…`, the
binary must be copied out or the service cannot find it.

## Why

A release snapshot is the last build layer, so the service VM boots with
everything the build left behind. identikey runs
`./target/release/identikey-server` straight out of `target/`, and its
release snapshot is ~1.2 GB for a ~14 MB binary. With caches, `target/`
moves to a mount that is not part of any layer, so there must be a
declared way to put build outputs into the release.

## What

- A step may declare `artifacts = ["<src>:<dest>", …]`. After the step
  succeeds, each `src` (relative to `/app`, or an absolute path such as
  `/cache/cargo-target/release/x`) is copied to `dest` inside the layer
  before the snapshot.
- A missing `src` fails the step, naming the path.
- `start_command` runs against the release as before. Apps that declare
  artifacts can point it at `dest` (e.g. `/app/bin/identikey-server`).
- Progress prints each artifact copied and its size, and the release
  snapshot's size.

## Impact

- Capabilities: ADDED requirements in `deploy-build`
- Modules: `Deploy.Manifest` (step `artifacts`), `Deploy.Orchestrator`
  (post-step copy), `Deploy.Builder` (size report)
- ADRs: none

## User journey & surfaces

The operator adds `artifacts` to the build step and points
`start_command` at the copied binary, then runs `mj deploy`.

- Working: `artifact target/release/identikey-server → /app/bin/ (14 MB)`
  and `release snapshot: <size>` (expected to drop from ~1.2 GB to a few hundred MB for identikey; measure).
- Empty: no `artifacts` behaves as today.
- Failed: `artifact target/release/identikey-server: not found` fails the
  build at that step; no cutover.
- Off: not applicable.

## Out of scope

- Shipping artifacts built outside Mjolnir (CI-built binaries): not
  tracked yet.
- Pruning build tools from the release (toolchains installed by earlier
  layers stay): a later "run from a slim base" change, not tracked yet.
