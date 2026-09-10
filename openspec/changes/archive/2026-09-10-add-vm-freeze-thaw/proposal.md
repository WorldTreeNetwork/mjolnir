# add-vm-freeze-thaw

> **ACTIVE BUILD**
>
> Folded 2026-09-10 → `openspec/specs/vm-freeze/spec.md`.

**Rigor:** change
**Bead:** mjolnir-3y6.10
**Steered:** 2026-09-03

## Why

`Mjolnir.MemorySnapshot.freeze/3` and `thaw/3` exist, but nothing public
calls them. `mj snapshot create` is filesystem-only and must stay that —
`vm.snapshot` is terminal for virtio-fs, so a silent `--memory` flag would
stop the VM. Operators need distinct verbs that say so at the point of use.

## What

- ADDED capability `vm-freeze`.
- `mj freeze <id> <name>` parks that VM into a named memory snapshot and
  tears the source VMM + virtiofsd down.
- `mj thaw <name>` restores the **same VM id**.
- `mj snapshot create` / existing filesystem callers unchanged.
- `mj snapshot list` / `show` surface `kind` (`filesystem` | `memory`).
- `mj spawn --snapshot` on a memory snapshot refuses and points at thaw.

## Impact

- Capabilities: ADDED `vm-freeze`
- ADRs: none

## User journey & surfaces

From a laptop, authenticated `mj`, against a running VM:

```
mj freeze <id> <name>
# VM has stopped. Restore with: mj thaw <name>
mj snapshot show <name>     # kind: memory
mj thaw <name>              # same VM id comes back
```

No new UI because this is the existing CLI and HTTP API.

## Out of scope

- Forking a new VM id from a memory snapshot (`mjolnir-8m3`)
- Wiring `handle_done` / DormantRegistry / `mj message` to freeze
- MCP freeze/thaw tools
- Compression / retention of memory-ranges (`mjolnir-3y6.9`)
- VMGENID (`mjolnir-3y6.13`)
