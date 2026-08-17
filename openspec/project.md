# Project context

Mjolnir is a distributed computational fabric for spawning checkpointable
Linux microVMs (Elixir/OTP orchestration, BTRFS CoW, Cloud Hypervisor,
vsock). This file is conventions. It is not a requirements store.

Requirements live in `openspec/specs/` (what is built) and
`openspec/changes/` (what should change). Reasoning that is not a
requirement lives in `docs/` and `docs/architecture.md`, and must name a
change-id when it implies work.

## Where work lands

| Kind of work | Lands in |
|---|---|
| New or changed behavior | `openspec/changes/<verb-led-id>/` |
| Restore intended behavior, typo, pin, comment, test for existing spec | Direct fix. No change. |
| Why the system is shaped this way | `docs/architecture.md` and `docs/decisions/` (amend, do not delete) |
| Hard-won fact | `bd remember` (not MEMORY.md) |
| Work-graph state | beads (`bd`) |

A change is the right landing zone when you can write a `#### Scenario:`
that fails today and passes after.

## Disposition banners

The first non-empty line of `proposal.md` after the title heading is a
banner. Status lives in the file because retrieval strips paths.

```
> **PENDING**
> **ACTIVE BUILD**
> **PARKED** — revive when <condition>
```

Agents draft PENDING. Humans replace it with ACTIVE BUILD (or you are
reading an activation in chat). PARKED is not available work.
