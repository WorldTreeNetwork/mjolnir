# Tasks

- [x] Fresh advise after preparation
- [x] Pin R1–R3 from `reviews/2026-11-11-advise.md` (contract text; fresh advise still owed)
- [x] Pin R4–R6 from `reviews/2026-11-11-advise-2.md` (selector, codec vector, write floor)
- [x] Pin R7–R8 from `reviews/2026-11-11-advise-3.md` (withdraw profile + single-record snapshot)
- [x] Delegation leaf encoding (member → consumer VM holder)
- [x] Trusted membership lookup client; inject `member(ks, pk)`
- [x] Admission-only: after try-lock, under deadline, fail-closed
- [x] Personal-fp offers skip lookup
- [x] Do not add Datalog membership to `mint` / `authorize`
- [x] Close architecture scenarios: Guild-scoped offers inject membership

## Owed from 2026-11-11 advise

- [x] R1 — Pin the member-signed delegation contract: canonical signed bytes/domain/version, algorithm and identity comparisons, guild/purpose/scope, validity, current-leaf discovery, and withdrawal/replacement/replay semantics; add the positive and adversarial scenarios named in [the review](reviews/2026-11-11-advise.md). (`mjolnir/aie-delegate/v1`, guild-wide, SecretStore current leaf)
- [x] R2 — Pin the trusted membership provider/adapter contract: configured authority per guild, authenticated and subject-bound responses, delegation evidence source, bounded freshness/future skew and deadline, and fail-closed/no-positive-fallback behavior; add malformed, stale, wrong-subject, timeout, and fresh-negative scenarios. (`Mjolnir.Aie.Guild.Roster`)
- [x] R3 — Pin the BEAM guild admission interface and enforcement point outside Biscuit Datalog, including verified offer/holder inputs, attempt/deadline binding, conjunction with Biscuit authorization, late-result refusal, and personal-policy bypass; add token-fact, key-mismatch, missing-gate, and abandoned-attempt scenarios and reconcile the generic member success scenario. (`Mjolnir.Aie.Guild.admit/1`)

## Owed from 2026-11-11 advise pass 2

- [x] R4 — Pin member/delegation selection from the actual `Guild.admit/1` inputs: selector or bounded discovery source, pending-request relationship, storage-owner derivation, and signer/roster/holder/guild comparisons; add valid discovery and missing/forged/wrong-member selector scenarios. See [pass-2 review](reviews/2026-11-11-advise-2.md). (pending-row `member_pk` untrusted selector)
- [x] R5 — Pin exact delegation signing bytes and envelope with a deterministic vector, validity boundaries, SecretStore codec/registration integration ownership, and separate storage/protocol fingerprint namespaces; add real-store publication/readback and malformed/wrong-purpose/wrong-namespace scenarios. See [pass-2 review](reviews/2026-11-11-advise-2.md). (Redeem grammar + `aie_delegate` codec; vector in design.md)
- [x] R6 — Pin publication/update/deletion authority and replay-resistant withdrawal/replacement across restart, distinguishing deliberate regrant from replay; add replayed-put-after-withdrawal, rollback-after-replacement, and restart scenarios. See [pass-2 review](reviews/2026-11-11-advise-2.md). (durable sequence floor; tombstone not generic delete)

## Owed from 2026-11-11 advise pass 3

- [x] R7 — Pin a member-authenticated withdrawal contract distinct from live-grant signing: signed operation/domain, target and sequence, validation and deterministic vector; cover authorized withdrawal, grant/tombstone substitution in both directions, wrong-target withdrawal, and stale tombstone replay after regrant. See [pass-3 review](reviews/2026-11-11-advise-3.md). (`mjolnir/aie-delegate-withdraw/v1`)
- [x] R8 — Pin coherent floor/current-leaf commit, admission-read, and crash-recovery semantics, including fail-closed partial/corrupt state and protection against generic floor mutation; cover interruption between writes, concurrent admission versus withdrawal/replacement, deletion failure, partial-state restart, and floor-reset attempts. See [pass-3 review](reviews/2026-11-11-advise-3.md). (single authoritative record; atomic rename)

## Out of scope

- Sidecar / flock — `add-aie-host-sidecar`
- Offer leaf — `add-aie-keyspace-claims`
- `mj` verb — `add-aie-guest-offer`
- Token guild-holder class (identikey-capability D5)
