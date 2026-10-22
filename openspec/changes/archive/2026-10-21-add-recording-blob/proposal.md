# add-recording-blob

> **ACTIVE BUILD**

**Rigor:** architecture

## Why

A recording is ciphertext in Blob Door. The data key is already wrapped to the owner's published X25519 by the client, and a friend wrap comes from IdentiKey rewrap. Mjolnir is the control plane that remembers which wrap belongs to which blob. It does not encrypt, decrypt, or hold a private key.

## What

- Add a recording index beside the existing content-addressed blob: Blake3 hash, owner XID, owner wrap, and later friend wraps.
- Register a wrap only for a hash the blob store already holds.
- Accept a friend wrap the caller already obtained. Do not call IdentiKey.

## Impact

- Capabilities: ADDED `blob-store` requirement for the recording index
- ADRs: none in this change. IdentiKey ADR-012 already describes rewrap. Blob door ADR 0003 stays the byte store.

## User journey & surfaces

No new UI because the owner encrypts on their own machine and the friend decrypts with their own X25519 scalar.

Working: the client PUTs ciphertext to the existing blob route, then registers the owner wrap. A later call stores one friend wrap for that hash. Empty: the hash is not in the store, so register inserts nothing. Failed: a second, different wrap for the same owner or the same friend is refused. Off: this process never returns a data key or a private scalar.

## Out of scope

- An HTTP unwrap that returns the data key. The 2026-10-21 choice keeps decrypt on the holder's own scalar.
- File encryption, IdentiKey login, and rewrap. Those already exist on the client and on `auth.identikey.me`.
- A new VM, a PRE proxy, OpenFHE, Umbral, or BN254.
- Changing Blob Door's bind, B2 layout, or the rule that ciphertext is fetchable by hash.
- Deploying this host or `auth.identikey.me`.
