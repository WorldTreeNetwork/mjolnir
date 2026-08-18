# Tasks

Architecture artifacts for `add-blob-store`. Advise 2026-08-17 sent
back; the four boxes are closed in this amend. Re-advise is next.

- [x] Write `design.md` (full argument)
- [x] Write ADR index `docs/decisions/0003-blob-store-mesh.md` as Proposed
- [x] Delta `specs/blob-store/spec.md` (ADDED)
- [x] Send-back: split “provider.” Canonical copy is B2. Working set is a disposable cache. Do not SHALL “a Mjolnir guest running MinIO.”
- [x] Send-back: written contrast (MinIO+B2 remote | iroh-blobs as archive | B2-direct + our door | iroh-blobs working set + B2 drain). Cite Mjolnir + Lightning Mesh Iroh transport; cite recrypt bao-tree vs iroh-blobs. E2E is transmit.
- [x] Send-back: `accepted ⇒ on B2` is HeadObject/GET before ack. ILM / async replicate are not an accept-path.
- [x] Send-back: hash-refuse and re-PUT no-op live on the put path, not raw S3.
- [x] Re-advise after the four boxes (`reviews/2026-08-17-readvise.md` accept-with-nits)
- [x] After accept: amend `~/work/Taskmaster/taskmaster-web/docs/ARCHITECTURE.md` with the sketch block in design.md
- [x] After accept: one-line hop in Taskmaster `docs/GHOST.md` (blob mesh, not the ready-set)

Handoffs (not checkboxes):

- `add-blob-api` — v1 door on B2 (REST / RPC / Mjolnir messages)
- `add-blob-client` after the door exists
- `add-iroh-blobs` — working-set / transmit on Mjolnir + Lightning Mesh
- `add-encrypt-blobs` after login + client
- identikey-core `ccf` and `add-sign-purpose` are other nodes
