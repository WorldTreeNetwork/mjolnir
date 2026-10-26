# add-lan-file-server implementation

The requirement text is
`openspec/specs/lan-files/spec.md`, folded from
`openspec/changes/archive/2026-10-24-add-lan-file-server/`.
This file records the vehicle. It does not add requirements.

## Guest

A small guest program, not a patch of `recrypt-server`. It links
`identikey-auth` and `recrypt-storage-auth`. It issues challenges
with one fixed service `aud`, maps a verified classical Ed25519
key to `Blake3(raw 32-byte key)` before the cap check, and refuses
a cap whose root issuer is not `ownership(h)`. Bytes go to
`blob_door_url` (`10.200.0.1:7222`). Caps and the ownership index
stay on the guest subvolume. The BEAM does not link either crate.

## IPv4 publish

DNAT on the Ethernet interface that holds the LAN address, aimed
at the guest HTTP port. When that interface has no address,
publish waits or fails. It does not bind `0.0.0.0`, `::`, or the
host GUA. The blob-door bind stays TAP-only, and the publish port
is not 7222.

## IPv6

A host userspace proxy, because TAP has no IPv6. That leg is
`mjolnir-h2fp.4`, with the stable ULA, not this change's LAN proof.

## Authenticated HTTP and caps (R1)

No server session. Each PUT and GET carries a fresh
`identikey-auth` Response. The guest verifies it with the fixed
`aud` and consumes the nonce. A replay or a wrong audience fails
closed.

`Verified` holds public keys, not the owner's signing key. The
guest does not mint a root Capability. The client signs a single
block whose root issuer is the owner. Parent-bearing chains are
refused in this landing.

The guest stores, with `ownership(h)`, the owner public key learned
from the first successful put. After restart that record is the
issuer-key lookup. A holder can GET with a fresh Response and a
still-valid cap without the owner connecting again.

`Capability::verify_full` is not the whole predicate. GET also
requires all of: unexpired signature, `SubjectKind::File`, subject
hash equal to the requested hash, `granted_to` equal to
`Blake3(raw holder key)`, `read`, and root issuer key equal to the
stored owner key (so the issuer fingerprint equals `ownership(h)`).
The recryption key stays with the client.

Negative checks: wrong audience, replayed proof, forged issuer,
wrong hash, wrong kind, wrong holder, expired or missing cap,
root issuer that is not the recorded owner.

## PUT success boundary (R2)

Order:

1. Verify the Response and that the body hashes to the claimed hash.
   Do this before any ownership write.
2. PUT the bytes to the blob-door and require its success. The door
   checks the hash. A lost response is a failure; the client retries.
   The same hash PUT is idempotent.
3. Register ownership. The first owner wins. The same owner
   registering again is idempotent. A different owner cannot replace
   it.
4. Acknowledge the PUT only after the door has accepted the bytes
   and the ownership record is durable on the guest subvolume.

A crash after the door accepts and before registration leaves an
orphan blob and no owner. Presence of the blob does not create
ownership. There is no DELETE rollback. A later putter becomes
owner only by completing this same sequence, including their own
door PUT of those bytes. A metadata failure after door success is
a failed PUT: no ownership is claimed from that attempt.
Concurrent different-owner PUTs cannot replace a recorded owner.
A malformed or failed PUT does not establish ownership.

## DNAT lifecycle (R3)

DNAT has no listening socket. The rule matches the named Ethernet
ingress, the IPv4 address currently assigned on that interface, and
the publish port. It rewrites only to that guest's TAP address and
HTTP port. It does not match every destination on the interface,
and it does not touch port 7222.

The Mjolnir host process owns the rule. Setup is idempotent when
the guest is running. It removes the rule on guest stop, on guest
replacement (then installs the new TAP target), and when the
Ethernet address disappears or changes. Address loss does not fall
back to `0.0.0.0`, `::`, or the GUA. FORWARD and the conntrack
return path cover this flow only.

Checks: inspect the installed rule; a LAN client GET succeeds; a
wrong interface, a wrong destination address, and an absent
Ethernet address do not publish. Mesh ULA stays on `mjolnir-h2fp.4`.
