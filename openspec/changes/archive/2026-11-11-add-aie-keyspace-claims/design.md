# Design

Implements ADR 0015 Decision 5. Does not change mint crypto.

## Decision — Record type

A new SecretStore record type for the AIE offer leaf. Canonical
bytes include owner fingerprint, local `offer_id`, named VM id,
being Ed25519 pubkey, sequence, optional guild/keyspace, allowed
catalog design ids, and maximum wall time. `canonical_bytes`
today sniffs Head/Manifest/Alias; this node adds the offer type.

SecretStore keyspace fp (`IdentiKey.fingerprint/1`) and holder
fp (auth-challenge v1 §5) stay different namespaces. The leaf
stores both.

## Decision — Incarnation and floor

Incarnation is Blake3 of the canonical signed leaf. Sequence is
strictly increasing. A tombstone is retained as a floor. Put at
or below the floor, including re-put of the exact retired bytes,
is refused. Replacement is a new leaf (new bytes, new sequence,
new incarnation). v1 revokes by whole-offer replacement.

## Decision — Allowlist

Publish and mint require the named VM's IdentiKey to equal the
keyspace owner and that VM id to be on this host's operator-held
allowlist. `VM.spawn/1` does not create the record.
