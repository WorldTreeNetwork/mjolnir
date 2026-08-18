# Tasks

Architecture artifacts for `add-blob-store`. Spawning MinIO is
`add-minio-mesh`, not a box here.

- [x] Write `design.md` (full argument)
- [x] Write ADR index `docs/decisions/0003-blob-store-mesh.md` as Proposed
- [x] Delta `specs/blob-store/spec.md` (ADDED)
- [ ] Advise accept (review-pair, reader = Grok) — flip ADR to Accepted
- [ ] After accept: amend `~/work/Taskmaster/taskmaster-web/docs/ARCHITECTURE.md` with the sketch block in design.md
- [ ] After accept: one-line hop in Taskmaster `docs/GHOST.md` (blob mesh, not the ready-set)

Handoffs (not checkboxes):

- `add-minio-mesh` after advise accept
- `add-blob-client` after the first provider exists
- `add-encrypt-blobs` after login + client
- identikey-core `ccf` and `add-sign-purpose` are other nodes
