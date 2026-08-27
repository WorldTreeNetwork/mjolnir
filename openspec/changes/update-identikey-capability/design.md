# Design — holder-bound Biscuit and foreign-secret redemption

**Status:** Proposed. ACTIVE BUILD. Advise not yet accepted.
**Change:** `update-identikey-capability`
**Folds into:** `identikey-protocol/docs/standards/identikey-capability-v1.md`
**Bead:** `mjolnir-axsb.1.1`
**Consumer architecture:** `add-secret-tokenator`

Grok authored. Advise reader must not be Grok (ADR-005). Fable 5 is
the cross-family reader. Sol is not subscribed.

## Problem

Five questions after intend:

1. Does the GitHub PAT travel with the agents?
2. Is a tokenator a betrayal of Recrypt D-5 (which rejected
   registry-style redemption because it learns every use)?
3. What binds “only agent Z may use this”?
4. What is the provenance of A → B → C → Z?
5. Do guilds / keyspaces change the token, or only the holder check?

## Decision 1 — Three layers stand. Tokenator is a verifier, not a fourth layer.

| Layer | Question | Spec |
|---|---|---|
| Identity | Who is this? | auth-challenge |
| Agency | What may this holder *do*? | Biscuit (this spec) |
| Data access | Who can read *our* ciphertext? | Recrypt PRE (D-5) |

`redeem` of a foreign secret is an agency operation: the Biscuit
carries `right(<secret_id>, "redeem")`. The tokenator is the
component that verifies that Biscuit and returns bytes it already
holds. It is the same shape as Mjolnir verifying `right(vm, "exec")`.
It is not a new crypto system.

Recrypt D-5 still holds: we do **not** put *our* ciphertext behind a
tokenator. PRE stays offline. GitHub PATs are not our ciphertext.
They cannot be recrypted into a form only Z can read without GitHub
participating. A holder that already stores the PAT is the honest
availability dependency.

## Decision 2 — The secret never enters the token

The Biscuit names a secret id (or equivalent resource). It does not
contain the PAT, an encryption of the PAT, or a URL that returns the
PAT without a holder check.

Anyone who steals only the Biscuit still needs the named private key
at redeem time (Decision 3).

## Decision 3 — Holder is a public key, proven at use

v1 holder class: **one Identikey public key**, and **only on the
secret-redemption profile**. VM-exec / mailbox biscuits are not
forced to carry a holder check (rbac-design Phase 1 stays valid).

Datalog: `check if holder($fp), $fp == "<blake3-fingerprint>"`.
Fingerprint is auth-challenge v1 §5 (Blake3 of the self-describing
key). HTTP proof carries `{alg, key}`; the verifier computes `fp`
and injects `holder(fp)`. Do not stuff raw key bytes into Datalog.

At redeem, the verifier:

1. Issues a single-use nonce (`aud` + `exp`).
2. Verifies a signature by that public key over (biscuit hash, nonce,
   audience).
3. Injects `holder(<fingerprint>)`.
4. Evaluates the Biscuit.

Possession of the Biscuit bytes is not enough. This is bearer-plus-
holder, the same *idea* as Recrypt D-5 §2, implemented with a
signature instead of PRE because the payload is a foreign secret.

v1 does not bind to “agent type” as a string the presenter self-
asserts. Type, if ever, is a fact the verifier injects from its own
catalog, not a claim in the token.

## Decision 4 — Hop provenance is the Biscuit block chain

The Biscuit block chain *is* the provenance log. Do not stand up
`identikey-log` for this.

Hops are monotonic: a forwarder may add checks, never remove the
holder check, never escalate.

v1 does not require intermediate agents to append a block. The
issuer may bind Z at mint and pass the same bytes through A, B, C.

When a hop *is* recorded in v1, it is **nextKey attenuation**: the
holder of the token bytes signs with the biscuit's current nextKey.
That is not the forwarder's Identikey. P-256 enclave keys do not
sign Biscuit blocks (capability-v1 §3.2). Identikey attribution per
hop is a **third-party block**, landed in `add-capability-hop`.

## Decision 5 — Guilds are a later holder class

A guild or Recrypt keyspace is membership in a set. That can be a
lookup the verifier injects (`member(<ks>, <pk>)`) or a
cryptographic proof. Not v1. The token shape does not have to change
when it arrives: a new check and a new injected fact.

## Rejected

- **Unsigned capabilities / verify-later as a protocol mode.**
  Already rejected in capability-v1 §3.3.
- **UCAN / Gordian envelope for agency.** Retired 2026-08-26.
- **Putting `resources` back on auth-challenge.** Still a possession
  proof, not a grant.
- **PRE of the GitHub PAT.** GitHub did not encrypt it to us.
- **identikey-log as hop log.** Duplicate of the block chain.
