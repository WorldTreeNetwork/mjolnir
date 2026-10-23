# add-memory-snapshot-usage

> **ACTIVE BUILD**

Bead `mjolnir-3y6.9`. Campaign grant on `mjolnir-3y6` (2026-10-23, "activate all" of the pinned ready-set).

## Why

A memory snapshot is a full RAM image under `@snapshots/<name>.mem`. `GET /api/storage` folds that directory into the `@snapshots` area, next to cheap CoW filesystem snapshots. Operators cannot see how much of the disk is frozen RAM.

Retention (one memory snapshot per VM, previous kept until the next freeze completes) landed in `62b43e5` and is already a living requirement. The btrfs root is mounted `compress=zstd`, which is the compression half of this bead. What is left is the separate usage report.

## What

- `Mjolnir.Storage.overview/0`, `GET /api/storage`, and `mj storage` report memory-snapshot count, logical bytes, and exclusive bytes apart from the `@snapshots` area.
- Do not add a second compressor. Document that on-disk size follows the volume's zstd mount.
- Do not reopen the retention rule.

## Impact

- Capabilities: ADDED requirement on `vm-freeze`
- Modules: `Mjolnir.Storage`, storage API, `mj storage` display
- ADRs: none

## User journey & surfaces

The operator runs `mj storage`. The snapshot area stays the CoW total. A separate memory-snapshot line shows the RAM images. Empty (no freezes) shows a zero count, not a missing field.

## Out of scope

- Changing retention (living requirement "A VM keeps one memory snapshot").
- `memory_restore_mode` / userfaultfd. That is restore latency, not size.
- Compressing with an extra zstd pass on top of the mount.

## Preparation

Outcome: revised. Bead asked for compression and retention. Retention is enforced in `lib/mjolnir/memory_snapshot.ex` (`retain_latest/3`) and specified in `openspec/specs/vm-freeze/spec.md`. Compression is the existing mount, per the bead note (~4.3x on a 512MB image). Deps closed. Authority: pinned epic grant, this node only. This change is the usage split only.
