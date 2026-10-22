# Design — holder-bound and bearer login profiles

**Status:** Proposed. PENDING. Revised 2026-09-24 after astra-arch-review send-back.
**Change:** `add-biscuit-profiles`
**Bead:** `mjolnir-22ff.5`
**Runtime:** `mjolnir-axsb.1.3` (not this change)

## Problem

JWT bearer on the API is possession-as-privilege. Direct auth should
default to a session key that must sign each request. A second
Biscuit stack would fork `identikey-capability-v1` and the tokenator
work.

## Decision 1 — Profiles, not a runtime

Mint/verify is `mjolnir-axsb.1.3` (Ed25519-rooted Biscuit, holder
check fail-closed, auth-challenge §5 fingerprints). This change
names the **login** profiles the edge will ask that runtime to mint.

`mjolnir-k8y.5` remains Phase 1 VM-spawn RBAC dual-mode with JWT. It
is related, not this landing.

## Decision 2 — Holder-bound is default

After the v1 Response + session bind, the edge mints a Biscuit that
checks `holder(<fp>)` for the ephemeral session public key. The
token MUST NOT assert that fact; the verifier injects it from a
request signature. Possession of the bytes is not enough.

## Decision 3 — Bearer is explicit and marked

Bearer issuance is a distinct profile (narrower rights, shorter
life). The token carries an unambiguous mode so a verifier that
implements only bearer cannot accept a holder-bound token by
skipping the signature.

ADR `0012-direct-edge-auth` is drafted by `add-edge-op-keys` and is
not yet in `docs/decisions/`. This profile does not depend on that
file existing; pin and audience come from the edge-auth deltas.

## Decision 4 — Per-request proof (finding 1)

Login proof v1 (this profile, not redeem): the session key signs
`["mjolnir-login/v1", biscuit_hash, method, path, body_hash,
edge_xid, nonce, exp]`. Replay owner is the edge nonce store
(`add-direct-auth-endpoints`). Concurrent reuse of the same nonce
fails. Invalid proof is fail-closed, not bearer fallback. The
verifier injects `holder(fp)` only after this proof succeeds; fp is
auth-challenge v1 §5 of the session public.

## Decision 5 — Mode is authority-block only (finding 2)

Profile discriminator is an authority-block fact `login_mode("holder")`
or `login_mode("bearer")`, signed by the mint root. Absent, unknown,
or conflicting modes reject. Attenuation MUST NOT remove or override
mode or the original `check if holder(...)`. Token-supplied `holder`
facts in any block are rejected. A bearer-only verifier rejects
`login_mode("holder")`.

## Decision 6 — Auth integration (finding 3)

Recognition: `Authorization: Bearer biscuit:<b64>` (distinct from
`mjsk_` and JWT). This branch runs **before** localhost bypass when
a biscuit is presented, so loopback cannot upgrade a narrow token.
Sites tokens remain first if `mjsk_` is presented. Success output:
subject XID, edge XID, `login_mode`, effective rights after
attenuation, expiry. Auth carries only those rights — never
`@all_scopes`. Ambiguous encoding fail-closed. Bearer lifetime and
right-set must be strictly less than the corresponding holder
issuance; overbroad bearer is rejected at mint. Audit: auth success /
deny / elevation with request id; no token bytes or keys in logs.

## Decision 7 — Login-proof bytes and nonce (advise-2 finding 1)

Encoding is canonical dCBOR of this 8-tuple, signed by the session
key (identikey-auth signature over
`["identikey-mjolnir/v1","login-proof", chal_bytes]` where
`chal_bytes` is that dCBOR):

1. `"mjolnir-login/v1"`
2. `biscuit_hash` — Blake3 of the **exact presented token bytes**
   (authority + every attenuation block as on the wire)
3. `method` — HTTP method, uppercase ASCII
4. `request_target` — path as received, plus `?` and the **raw
   query string** when a query is present (no decoding, no
   reordering). `GET /api/vms?session=a` and `GET /api/vms` are
   different. No query means path only, no trailing `?`
5. `body_hash` — Blake3 of exact body bytes (empty body = Blake3 of
   `<<>>`)
6. `edge_xid` — 64 lowercase hex of the pinned edge
7. `nonce` — 32-byte value **issued by the edge**
8. `exp` — Unix seconds; MUST be ≤ token expiry and ≤ nonce expiry

Nonce store (`add-direct-auth-endpoints` implements): edge issues
`{nonce, nbf, exp}` as outstanding; proof must name an outstanding
nonce. Consume is atomic with accepting the protected effect.
Concurrent reuse fails. After `exp`, eviction, or store loss on
restart, the nonce is unknown → fail closed (not “maybe replay”).
Numeric windows are config; the rules are not. Wire transport of
the proof (header vs body) is an endpoint choice, not this profile.

## Decision 8 — Authorization result is for this request (advise-2 finding 2)

Adapter trusted inputs: operational mint root + current delegations
from `add-edge-op-keys`, expected local edge XID, now, holder
evidence from Decision 7, requested operation, and request facts
(including path/query resource ids such as `vm_id`). All Datalog
checks and expiry run here. Output is a **one-shot decision**:
allow/deny for this request, plus subject XID, edge XID, mode, and
token expiry for audit. It is not a reusable ambient scope list.
A token attenuated to `vm=A` that is then used for `vm=B` is deny.
Foreign root or expired capability/delegation is deny. Deny does
not populate `conn.assigns` claims and does not fall back to JWT
or localhost.
