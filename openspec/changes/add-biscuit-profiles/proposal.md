# add-biscuit-profiles

> **ACTIVE BUILD**

Bead `mjolnir-22ff.5`. Steer 2026-09-24.

**Rigor:** architecture

**Preparation (2026-09-24 /run):** still valid contract (advise-3 accept). Deferred this wave: inbound mint/verify artifact `mjolnir-axsb.1.3` is OPEN with no `biscuit-auth` in-tree. Do not guess a second runtime. Authority: 22ff campaign, profiles-only steer.

## Why

Direct auth mints an edge-scoped capability. If that token is a
bearer JWT-shaped secret, theft is privilege. identikey-capability
already named holder-bound Biscuits. This node is the Mjolnir login
profile, not a second mint/verify runtime.

## What

- Default profile: holder-bound. The IdentiKey exchange authorizes an
  ephemeral session public key; every protected request proves
  possession. Holder fingerprint is auth-challenge v1 §5.
- Bearer is an explicit issuance option: shorter lifetime, narrower
  authority, unambiguous mode bit so a verifier cannot treat
  holder-bound as bearer.
- Integrate with `mjolnir-axsb.1.3` (mint/verify). Do not implement
  mint here. `mjolnir-k8y.5` stays VM-spawn RBAC.

## Impact

- Capabilities: ADDED `edge-auth`
- ADRs: none (cite `0012-direct-edge-auth` and
  `identikey-capability-v1`)

## User journey & surfaces

No new UI because `Authorization` on the existing API is the
surface. After later endpoints, `mj` stores a holder-bound
capability next to the session key.

- **Working (after act)** — a stolen holder-bound token without the
  session private key fails; an explicit bearer token works until
  expiry and is distinguishable.
- **Empty** — no mint runtime yet (`mjolnir-axsb.1.3`); this change
  is the contract and vectors.
- **Failed (today)** — API is JWT or localhost bypass; no Biscuit
  path in `Mjolnir.API.Auth`.
- **Off** — hosted JWT still valid (`add-offline-jwks`).

## Out of scope

- Mint/verify NIF — `mjolnir-axsb.1.3`
- VM-spawn RBAC biscuits — `mjolnir-k8y.5`
- HTTP mint at login — `add-direct-auth-endpoints`
- Tokenator redeem — `mjolnir-axsb.1.4`
- Numeric lifetimes (skipped at steer; pick at endpoints)
