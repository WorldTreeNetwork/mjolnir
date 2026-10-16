# steer add-direct-challenge

**When.** 2026-09-24
**Depth.** explicit

## Decided
- Protocol home: identikey-auth v1 as-is; session bind is a second step (user)
  Why: keep auth ≠ authorization; do not fork Papyrus/peer Challenge; identikey-core is not the edge verifier.
- Managed Sign+Auth is Ed25519, not Schnorr (user, on 22ff.3.1)
  Why: blob is unused as a Signer; v1 already has Ed25519; do not extend the protocol.
- C1/C2 claimant is 22ff.3.1, not an OIDC wrapper (user + existing child)

## Skipped
- Keycloak UUID `owner_id` migration
- Exact encoding of the second authorization object (this change names it; advise may nit the bytes)

## Feeds change
Mjolnir consumes identikey-auth. `aud` = pinned edge XID. Second signed object carries session key / operation / channel. Nonce consumption and capability issuance are atomic on the edge (implemented in `add-direct-auth-endpoints`).
