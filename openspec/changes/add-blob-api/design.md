# Design — blob door (v1)

Implements ADR 0003 Decision 1b. Not a new ADR.

**Status:** PENDING
**Change:** `add-blob-api`
**Parent:** `add-blob-store` (accepted shape)

## Pins (advise nits)

1. **HTTP first.** Same contract Sites already wrote
   (`docs/plans/initiatives/identikey-sites.md`,
   `lib/mjolnir/sites/storage/recrypt.ex`):

   ```
   PUT  /storage/blob/b3/{hash}         body = stored bytes
   PUT  /storage/blob/b3/{hash}.obao    body = outboard
   GET  /storage/blob/b3/{hash}         -> stored bytes
   GET  /storage/blob/b3/{hash}.obao    -> outboard (404 = none)
   HEAD /storage/blob/b3/{hash}         -> 200 if accepted
   ```

   `{hash}` is base58 of the 32-byte Blake3. Do not invent
   `/blob/put`. A Mjolnir-message face can wrap the same put path
   later; `deliver_message` maxes at 16 MB
   (`mjolnir_protocol/src/lib.rs:48`) and is not the large-blob
   path.

2. **Process, not a store VM.** Sidecar on the Mjolnir host (Linux),
   next to how Sites planned the recrypt-storage sidecar. Recrypt
   does not compile on macOS; the door that talks to B2 runs on
   Linux. Laptop Taskmaster is an HTTP client (`add-blob-client`).
   Loopback or the private guest net. Not a new VM class. Not MinIO.

3. **Put path is a wrap, not raw `S3Storage`.**
   `put` hashes (`recrypt-storage/src/s3.rs:122–130`).
   `put_with_outboard` does not (`s3.rs:217–248`). The door:

   - hashes ciphertext with real Blake3 (not Sites.Crypto stub)
   - refuses mismatch
   - `HeadObject` on B2: if present and same size/hash, no-op
     (versioning-on must not create a second version)
   - PUT ciphertext (and `.obao` if any)
   - `HeadObject` or GET on B2 **before** 201/200 accepted
   - never returns accepted on PUT 200 alone

4. **Keys stay on the door.** B2 application key via Mjolnir
   managed secrets on the host sidecar. Taskmaster and other
   callers never receive it. A second principal may `DeleteObject`;
   the caller principal cannot. Versioning is on.

5. **v1 locator.** `ProviderIndex` maps hash → door URL. Canonical
   durability is still B2 (ADR 0003). After the door dies, proof
   is GET/Head from **B2**, not “a replacement provider.”

## What we reuse

Sites’ Recrypt adapter is the HTTP client shape. The door may be
a thin Rust binary using `recrypt-storage` (Linux only) or any
process that speaks the layout bit-for-bit. We do not take
recrypt-server’s `/files` multisig surface as this door.

## Not this change

Streaming multipart inside the door is owed if the first PUT
cannot hold the object in RAM. Recrypt’s `Vec<u8>` is a client
limit; B2 multipart exists. First act may stream or document a
hard size cap — not silent OOM.
