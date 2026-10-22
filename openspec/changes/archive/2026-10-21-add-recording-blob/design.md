# add-recording-blob

## Decisions

1. **The client encrypts.** This process receives ciphertext bytes that already match a Blake3 the blob store accepted, plus a wrap the caller claims is an `x25519-xchacha20poly1305` data-key wrap. It does not generate a data key and it does not unwrap.

2. **The blob stays the ciphertext.** The existing `PUT /api/sites/blob/:hash` path stores the bytes. The new index stores only the hash, the owner XID, and wrap bytes. Friend wraps are more rows for that hash. Rewriting the blob to append a friend is impossible: the hash would change.

3. **First wrap wins, bound to the JWT subject.** Register, friend add, and GET require `principal_kind == :user`. The row stores that JWT `sub`. A `:capability` biscuit (`user_id` is the constant `"capability"`), a `:sites` token, an `:operator` (`"localhost"`), a `:ceremony`, or a `:public` caller is refused before any probe or write. The same owner wrap from that same `sub` is success. The same owner wrap from a different `sub` is refused. A different owner wrap is refused. A friend add or an index read from any other `sub` is refused. A friend XID equal to the owner XID is refused. The owner XID is the registrant's claim, not a proof. The self-friend check compares that claim. This index does not deliver a wrap to a friend. The friend receives their wrap from the owner, because Mjolnir cannot authenticate an XID. An empty wrap, or a wrap larger than 4096 bytes, is refused. A wrap that is not a CBOR map with `alg` `x25519-xchacha20poly1305` and a 48-byte `ciphertext` field is refused, and it is not decrypted. The owner-slot race remains: the first `:user` to register a hash owns that row. That is not the chunk route. A chunk write is deterministic. This row is not. The check-and-write runs inside the `Store` GenServer, so two different wraps cannot both win. The file is `<sites_root>/recordings/<hash58>.json`, outside `blob/b3/`. The client keeps its own copy of the owner wrap. The sites backup copies the file on its daily run, not at the moment of the ack.

4. **Presence is a HEAD, not a download.** Before insert, the door backend sends `HEAD /storage/blob/b3/{hash}`. The local backend uses a file stat. Neither path calls `Store.has_chunk?` or `get_chunk`. A missing object inserts nothing.

5. **The row is a file under the sites root.** Write it with the same atomic fsync-and-rename `Store` already uses, under the sites root, so `mjolnir-sites-backup` copies it. A restart reads that file. Postgres is not the source of truth. It may be absent.

6. **No IdentiKey call.** The friend wrap is the body `POST /account/encapsulation/rewrap` already returned to the owner. This service stores those bytes. It does not check that they decrypt.

7. **One blob, one body limit.** A v1 recording is one ciphertext object already accepted by `PUT /api/sites/blob/:hash`, inside that route's 64 MiB body. A chunked or manifest-keyed recording is out of scope.

8. **Routes.** JSON, under the existing Sites router. `POST /api/sites/recordings` with `hash`, `owner_xid`, and unpadded base64url `wrap`. `POST /api/sites/recordings/:hash/friends` with `friend_xid` and `wrap`. `GET /api/sites/recordings/:hash` returns the index only to the registering principal: hash, owner XID, owner wrap, friend wraps. Another principal gets a refusal, not an empty list. The body does not contain ciphertext or a data key. Ciphertext remains `GET /api/sites/blob/:hash`. The friend list is new social-graph metadata, so it is not world-readable the way the ciphertext hash is.

9. **XID text is base58btc.** Store it as text. Do not treat a Sites fingerprint or `user_id` as an XID. Changing the owner's published X25519 after this row exists is out of scope. Recovery is a new ciphertext and a new hash.

## Non-decisions

Playback, export of the scalar, and a wallet stay outside this change. Replacing an owner wrap after the owner's X25519 changes is a later change. A chunked recording is a later change.
