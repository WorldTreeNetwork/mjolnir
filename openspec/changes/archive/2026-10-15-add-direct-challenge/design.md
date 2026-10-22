# Design — direct challenge consumer

**Status:** Proposed. ACTIVE BUILD. Revised 2026-09-24 after astra-arch-review advise-4.
**Change:** `add-direct-challenge`
**Bead:** `mjolnir-22ff.3`

## Problem

`mj login` today is OIDC (device-code on Keycloak, loopback PKCE on
IdentiKey). identikey-auth v1 already has audience, nonce, expiry,
and a self-describing key. The epic wanted extra fields (operation,
session key, channel) on that Challenge. Putting them there mixes
identity with authorization and forks every other v1 verifier.

## Decision 1 — v1 identity, second-step bind

Identity proof is `identikey-auth-challenge-v1` unchanged.
`Challenge.aud` is the pinned stable edge XID.

Authorization bind is a separate signed object: ephemeral session
public key, requested operation, channel context, bound to the
challenge bytes just answered. The edge verifies identity first,
then the bind, then mints (`add-direct-auth-endpoints`).

## Decision 2 — Two claimants, one Response shape

C3/C4 sign locally. C1/C2 may ask identikey-core to sign the same
canonical Challenge after fresh A3/A4 consent
(`add-managed-challenge-responder`). The edge does not learn custody
rung from the Response (protocol §8.1).

## Decision 3 — No Schnorr on the wire

Managed operational Sign+Auth becomes Ed25519 (steer on 22ff.3.1).
identikey-auth v1 is not extended.

## Decision 4 — Bind signing contract (R1)

The bind is signed by the **same classical public key** that
verified the v1 Response. Domain: `["identikey-mjolnir/v1","bind",
chal_bytes, session_pub, operation, resource, channel]`. Operation
and resource are canonical tuples; local policy must allow that
operation or the bind is rejected even if the signature verifies.
Accepted authorization is limited to that session key +
operation/resource. Session-key possession on later requests is
owned by `add-biscuit-profiles`, not a third login object.

C1/C2: `add-managed-challenge-responder` must also sign this bind
(same holder key) after consent that covers Challenge digest **and**
the bind fields. The operator’s Challenge Response is not consent
and cannot authorize the bind (upstream §8.1). If the managed
signer cannot produce the bind signature, this flow is incomplete
for C1/C2 — do not infer it from the Response.

## Decision 5 — Channel is authenticated peer/session (R2)

Channel context is **adapter-supplied authenticated inputs**, not a
client-chosen string. For HTTP/vsock/Iroh: the verifier compares the
signed channel to the current connection’s authenticated peer
identity for this exchange (edge proof from `add-edge-op-keys` plus
connection id). If those inputs are unavailable, refuse. A valid
bind replayed on another connection of the same transport is
rejected. A wrong peer advertising the correct `aud` is rejected
because edge-proof of the pin failed, not because `aud` strings
differed.

Supported transports for v1: the existing API HTTP(S) and Iroh
(mj connect). Others are out until an adapter is named.

## Decision 6 — Atomic consume vs bind (R3)

Do not call identikey-auth `verify_response` in a way that burns the
nonce before bind+issuance commit. Use a transaction-scoped nonce
store: identity verify, bind verify, then **one** commit that
consumes the nonce and records issuance. Invalid bind after valid
identity: nonce not consumed; client may retry bind or get a fresh
challenge. Concurrent duplicates: one commit wins; the other is
replay. There is no durable `consumed-without-issue` state.
Expiry of an unused proof is its own vector, independent of
replay.

## Decision 7 — Residual after advise-2 / advise-4

Channel authority is the TLS terminator that serves the pinned API
origin certificate. For public HTTPS that terminator is
`mjolnir-gateway`. On accept of an origin-TLS session the gateway
allocates a `server_conn_id` unique to **that** external connection
and computes
`channel = Blake3(SPKI(served_origin_cert) || server_conn_id)`.
The Challenge companion field returns that `server_conn_id` on the
same connection (not a v1 Challenge key). The bind copies it.

The gateway forwards to Bandit only over a trusted backend
(loopback TCP or UDS). It strips any client-supplied
`X-Mjolnir-Conn-Id` / `X-Mjolnir-Origin-Spki` and injects the
values for this session. Bandit accepts those hop-auth fields
**only** from that trusted peer; a request that did not arrive on
the trusted hop has no channel → refuse. Each backend request maps
one-to-one to one external TLS session. The verifier computes the
expected channel from the **injected** conn_id and origin SPKI,
independently of the bind’s copied id, then compares. Looking up
channel only by Challenge bytes, or treating the copied id as the
comparison value, is forbidden (that would accept an unconsumed N1
proof on N2).

Iroh has no gateway hop. Channel =
`Blake3(peer_iroh_node_id || conn_id)` where `conn_id` is assigned
by the edge on that Iroh connection and returned beside the
Challenge. The node id MUST match the operational-key edge-proof of
the pin. Plain HTTP is deferred (no authenticated adapter).

Same-transport replay: an **unconsumed** proof first presented on
`N2` is rejected for channel mismatch without consumption; the
same proof is then accepted on `N1` (exactly one issuance); a
further submit on `N1` is replay.

Atomic recovery: **issued** is distinct from **delivered**. Invalid
bind or any failure before commit → nonce unconsumed; retry bind on
the same challenge (same connection) or start over. One commit
records nonce consumption **and** issuance together. No usable
credential exists before that commit. After commit, delivery loss
does not undo the record and does not mint a replacement from the
old proof; the client starts a new challenge. Restart restores the
last commit. If restart closed `N1`, a retry is a new connection
and therefore a new challenge (channel includes `conn_id`).
Concurrent submissions: exactly one commit wins.
