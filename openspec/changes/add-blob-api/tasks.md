# Tasks

Owed when this change is ACTIVE BUILD. Do not start at PENDING.

- [x] Door process on the Mjolnir host (Linux sidecar). Not a new VM. Not MinIO.
- [x] HTTP routes: `PUT/GET/HEAD /storage/blob/b3/{hash}` and `.obao`
- [x] Put path: Blake3 refuse, exists-then-skip, B2 write, HeadObject/GET, then ack
- [x] Wrap `put_with_outboard` so hash-mismatch cannot land
- [x] B2 keys only in the door (managed secrets). Callers cannot DeleteObject
- [x] B2 versioning on (bucket op; documented in `blob-door.env.example`)
- [x] Real Blake3 — not `Mjolnir.Sites.Crypto.blake3_hash/1`
- [x] Prove: PUT accepted → drop door → GET from canonical store (memory stand-in; live B2 at deploy)
- [x] Prove: mismatched hash is refused; re-PUT of the same bytes is a no-op (no extra version)

Handoffs (not checkboxes):

- `add-blob-client` — Taskmaster talks to this door
- `add-iroh-blobs` — mesh working set; iroh locator grammar
- `add-encrypt-blobs` — personal + PRE / Guild-Key
- Other RPC / Mjolnir-message faces — same put path, later
