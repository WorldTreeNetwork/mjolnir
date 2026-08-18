# Tasks

Architecture artifacts for `add-blob-store`. Spawning a working-set
VM is not a box here. Advise 2026-08-17 sent back; close these
before re-advise.

- [x] Write `design.md` (full argument)
- [x] Write ADR index `docs/decisions/0003-blob-store-mesh.md` as Proposed
- [x] Delta `specs/blob-store/spec.md` (ADDED)
- [ ] Send-back: split “provider.” Canonical copy is B2 (or equivalent). Working set is a disposable cache (B2-direct, LocalFileStorage, MinIO, or iroh-blobs FsStore). Do not SHALL “a Mjolnir guest running MinIO.”
- [ ] Send-back: replace the iroh-blobs one-liner with a written contrast (MinIO+B2 remote | iroh-blobs+B2 drain | B2-direct). Cite existing Iroh transport in Mjolnir and Lightning Mesh; cite recrypt’s bao-tree vs iroh-blobs crate decision. Name E2E as transmit, not store confidentiality.
- [ ] Send-back: `accepted ⇒ on B2` is HeadObject/GET on B2 before ack. Strike ILM / async replicate as an accept-path.
- [ ] Send-back: move hash-refuse (and re-PUT no-op) onto the put path (`BlobStorage` / sidecar), not onto raw MinIO.
- [ ] Re-advise after the four boxes
- [ ] After accept: amend `~/work/Taskmaster/taskmaster-web/docs/ARCHITECTURE.md` with the sketch block in design.md
- [ ] After accept: one-line hop in Taskmaster `docs/GHOST.md` (blob mesh, not the ready-set)

Handoffs (not checkboxes):

- First implement node is named after the contrast picks a landing (not assumed to be `add-minio-mesh`)
- `add-blob-client` after the first provider exists
- `add-encrypt-blobs` after login + client
- iroh-blobs as working-set/transmit is a later node if the contrast parks it
- identikey-core `ccf` and `add-sign-purpose` are other nodes
