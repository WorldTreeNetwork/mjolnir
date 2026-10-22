# Tasks

- [x] Fresh advise after preparation — opus-arch-review accepted in `reviews/2026-10-21-advise-3.md`; reviewed contract SHA-256: proposal `cffaec4bfa79b27b822e4a1d9d925ed9d0fee0c168ee6e9fea99b98040ff8367`, design `abc45dbf341e44b4645dfab666b20aecb013fef4c9ea97d721507de2d7ff8af5`, spec delta `780871a7f8d3c6bff789a0b3c5b9a54d6e9c7f654b7f5d258a39eab4bee3c875`.
- [x] Record an owner wrap only for a JWT `:user`, bound to `sub`, and only when a HEAD or a local file stat says that ciphertext hash is already stored. Do not GET the ciphertext. Refuse a biscuit, a Sites token, an operator, a ceremony, and a public caller before any probe. The same wrap from that `sub` is success. A different wrap, or the same wrap from a different `sub`, is refused. An empty, oversized, or non-wrap body inserts nothing.
- [x] Record one friend wrap per friend XID for that hash, only from the registering `sub`. Refuse any other `sub`. Refuse a friend XID equal to the owner. Do not call IdentiKey. Do not treat the index as the friend's delivery path.
- [x] `GET` returns the index to the registering `sub` only, and not the ciphertext, the data key, or a scalar.
- [x] The row is an atomic fsync-and-rename file at `<sites_root>/recordings/<hash58>.json`, written through the `Store` GenServer. A restart reads it. Postgres is not required.
- [x] Tests cover first-wrap-wins, two concurrent different wraps, a missing blob, a self-friend, a different `sub`, a biscuit, a Sites token, no ciphertext download, a restart, and a raw 32-byte body.

## Owed from advise 2026-10-21 (send-back)

Contract text now includes these. The fresh reader confirms them.

- [x] B1: Store the authenticated principal (`conn.assigns.user_id`) on the owner row. A friend add from any other principal is refused. The owner-slot race is stated as not the same as the chunk route. Spec scenario: a different principal's friend add is refused.
- [x] B2: The existence probe is a door `HEAD /storage/blob/b3/{hash}` (or a file stat for Local), never `Store.has_chunk?`/`get_chunk`. Spec scenario: register does not GET the ciphertext.
- [x] B3: Rows are atomic-fsync files under the sites root, covered by `mjolnir-sites-backup`. Postgres is at most absent. Spec scenario: a row survives a restart.
- [x] N1: A v1 recording is one blob within the existing 64 MiB body. A chunked or manifest-keyed recording is out of scope.
- [x] N2: `GET` is only the registering principal, because the friend list is social-graph metadata.
- [x] N3: Owner wrap-target rotation is out of scope. Recovery is a new ciphertext and a new hash.

## Owed from advise-2 2026-10-21 (send-back, `reviews/2026-10-21-advise-2.md`)

- [x] C1: Register, friend add, and GET require `principal_kind == :user` and bind the row to the JWT `sub`. Refuse `:capability`, `:operator`, `:sites`, `:ceremony`, and `:public` before any probe or write. Spec scenario: a biscuit caller and a Sites-token caller are refused, and no row is written. Sites tokens are not a v1 binding.
- [x] N4: Check-and-write is the `Store` GenServer. Path is `<sites_root>/recordings/<hash58>.json`, outside `blob/b3/`. Test: two concurrent registers with different wraps give exactly one success.
- [x] N5: A wrap must be a CBOR map, `alg` `x25519-xchacha20poly1305`, with a 48-byte `ciphertext`. It is never decrypted. A raw 32-byte value is refused.
- [x] N6: The row reaches B2 at the next daily sites backup, not at ack. The client keeps its owner wrap until then.
- [x] N7: `owner_xid` is the registrant's claim, not proof. The same owner wrap from a different principal is refused. The friend gets their wrap from the owner, not from this index.
