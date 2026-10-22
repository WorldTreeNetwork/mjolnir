# steer add-recording-blob

**When.** 2026-10-21
**Depth.** standard

## Decided

- Playback: the friend decrypts with their own X25519 scalar (user)
  Why: IdentiKey rewrap already returns a wrap. Returning the data key from IdentiKey was the option not chosen.
- Store: ciphertext in the existing Blob Door, wraps in a Mjolnir index (auto)
  Why: the door is content-addressed and has no mutable row. A friend wrap cannot be appended to the blob without changing its hash.
- Proxy VM: not in this change (auto)
  Why: the accepted share scheme is custodial rewrap, not a PRE proxy. The door already exists.

## Skipped

- None.

## Feeds change

The client encrypts and wraps. Mjolnir records the Blake3 of the ciphertext and the wrap bytes. It does not decrypt, does not call IdentiKey, and does not deploy a new VM.
