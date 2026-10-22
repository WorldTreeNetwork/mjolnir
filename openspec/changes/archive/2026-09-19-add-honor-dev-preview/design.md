# Design — grok + Vite on the ticket URL

Canonical: ADR
[`0011`](../../../docs/decisions/0011-honor-being.md) §§2, 5–7.

**Change:** `add-honor-dev-preview`
**Bead:** `mjolnir-x97p.5`

## Decision 1 — snapshot of ubuntu-24.04, not @base/hosted

Bootstrap once: bun, git, grok binary, repo clone. Snapshot as
`hosted-<xid>` under `@snapshots/`. Catalog stays OS roots.

## Decision 2 — XAI_API_KEY in tmpfs

Inject like other opaque material. Never on the BTRFS subvolume.
No grok.com session.

## Decision 3 — ticket URL is the preview; CORS is a sibling

Vite binds `0.0.0.0`. Gateway already maps ticket → guest HTTP.
If HMR websocket fails through Iroh, document it; first paint is
the gate. Exact-origin CORS is `mjolnir-x97p.6` once a ticket
exists.

## Decision 4 — clone in guest

`extra_mounts` is still ignored. Do not block this node on
`mjolnir-gge.1.9`.
