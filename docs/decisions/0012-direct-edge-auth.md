# ADR 0012: Direct edge authentication uses a pinned stable XID

**Status:** Accepted

## Decision

Direct clients trust an explicitly configured stable edge XID. Discovery
(DNS, `.mesh`, Babel, Iroh, or any later mechanism) supplies an address only;
it never supplies or changes the trust pin. A first connection without a pin
fails closed. This is not TOFU, and `authlocal.identikey.me` is not an issuer,
discovery service, or fallback trust root for this path.

The stable identity is Ed25519. Its Gordian-style XID is the lowercase hex
SHA-256 digest of **exactly the raw 32-byte Ed25519 inception public key**—no
CBOR wrapper, algorithm label, document label, or text encoding is hashed.
Consequently, a document carrying another edge's XID cannot bind an attacker
key to that pin.

The stable private key delegates short-lived operational Ed25519 keys. The
delegation is an Ed25519 signature over canonical dCBOR:

```text
["identikey-mjolnir/v1", "op-delegation", op_pub, kid, edge_xid,
 ["edge-proof", "cap-mint"], nbf, exp, true]
```

`op_pub` is a CBOR byte string. The final `true` means no onward delegation.
The exact purpose set is required. Ordinary edge proof and capability minting
use the operational private key; they do not open or require the stable
private key.

Rotation retains every still-valid, unrevoked delegation needed to verify
live capabilities. Revocation has one representation only:

```text
["identikey-mjolnir/v1", "op-supersede", kid, exp_now, next_kid]
```

`exp_now` is the revoked key's effective revocation time, not the record's
expiry. A late-received valid record still revokes. `next_kid` is only a name;
the successor needs its own delegation. Operational-key compromise uses this
supersession path. Stable-private compromise does not: the edge creates a new
identity and clients receive a new pin, because the leaked root can authorize
arbitrary records under the old pin.

## Persistence and recovery

Identity and operational state live in `/var/lib/mjolnir/auth` (config key
`:auth_dir`), never under the resolved `btrfs_root`. The directory is `0700`;
files containing private material are `0600` both when created and whenever
opened. State aliases into BTRFS are rejected. Activation atomically renames a
synced bundle containing the current operational private key, its matching
delegation, current kid, retained delegations, and supersessions. Generating a
key does not activate it.

Missing or corrupt established operational state fails direct authentication
closed. Hosted JWT verification is independent. If the stable private key is
offline, a valid persisted bundle still supports ordinary sessions and
restart, but cannot rotate itself.

A stale backup is reconciliation input, not live authority. Restore requires
a fresh stable-key signature over:

```text
["identikey-mjolnir/v1", "auth-restore", bundle_hash, restore_id,
 observed_revocations_hash, issued_at]
```

The operator obtains current revocation evidence independently, merges it
into the public state represented by `bundle_hash`, and attests that result.
An old backup plus its old attestation cannot revive a later-superseded kid.
Without current evidence, direct auth remains unavailable. Root loss without
leak may use this ceremony; root loss without usable recovery material creates
a new identity and pin.

## Consequences

The edge can authenticate directly and offline from hosted identity services,
while the stable root stays off the ordinary hot path. Offline verifiers can
lag revocation until they receive a supersession or the delegation expires;
the delegation expiry bounds that exposure. Host compromise can expose the
online operational key, an accepted v1 tradeoff. Hardware custody is separate
work.
