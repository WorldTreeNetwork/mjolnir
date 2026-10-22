## ADDED Requirements

### Requirement: Hosted JWT verification survives issuer outage

The edge SHALL persist the last **validated** JWKS for the configured
hosted issuer under `/var/lib/mjolnir/auth` (directory mode `0700`,
file mode `0600` at creation). The path SHALL NOT be under
`btrfs_root`; a configured path that aliases into `btrfs_root` SHALL
be rejected without using it. Process start SHALL NOT require a live
JWKS fetch. Unexpired tokens whose `kid` is in the **active** (memory) set for
**this issuer** SHALL verify while the issuer is unreachable, subject
to the same signature, algorithm, issuer-claim, and expiry checks as
a live-key verification. After a successful persist or a disk-only
boot, that active set equals the persisted set. A token whose `kid`
is absent from the active set SHALL be rejected. The active set SHALL be the last
validated JWKS document for this issuer (replacement, not union).
Neither an empty cache nor a disabled issuer SHALL
grant authentication.

#### Scenario: Reboot with issuer down

- GIVEN a persisted JWKS bound to issuer I that includes `kid=A` and
  an otherwise-valid unexpired hosted ID token for I signed by `A`
- WHEN the edge starts with I unreachable
- THEN the token verifies
- AND the process does not fail start for lack of a live JWKS fetch

#### Scenario: Unknown kid is rejected

- GIVEN the **active** issuer-bound set does not include `kid=Z`
  (disk-only boot of a cache without `Z`, and no later successful
  fetch that added `Z`)
- WHEN a token headed with `kid=Z` is presented
- THEN verification fails

#### Scenario: Issuer-set retirement across restart

- GIVEN persisted keys `{A,B}` for issuer I
- WHEN a later validated fetch for I returns `{B}`, persist of `{B}`
  succeeds, and the process then restarts with I unreachable
- THEN tokens signed by `B` still verify while unexpired
- AND tokens signed by `A` are rejected even if unexpired

#### Scenario: Operator cache delete withdraws trust

- GIVEN persisted keys for issuer I and a running signer table
  that has loaded them
- WHEN the operator stops the process, deletes that issuer’s
  cache file, and starts with I unreachable
- THEN hosted JWT verification fails closed
- AND the process still starts
- AND an empty JWKS from I would not have cleared the cache

#### Scenario: Issuer-set overlap then retirement

- GIVEN active and persisted `{A}` for issuer I
- WHEN a validated fetch returns `{A,B}` and persist succeeds
- THEN both `A` and `B` verify
- WHEN a later validated fetch returns `{B}` and persist succeeds
- THEN `B` verifies and `A` is rejected even if unexpired
- AND after restart the same `{B}`-only set is loaded

### Requirement: JWKS cache is bound to issuer and source URL

The on-disk cache SHALL record the configured issuer and the
effective JWKS URL (trailing slashes trimmed). Load SHALL reject a
cache whose binding does not match current config. Rejection SHALL
not prevent boot. Token `iss` checks SHALL still use the configured
issuer.

#### Scenario: Issuer switch cannot reuse old keys

- GIVEN a cache bound to issuer X containing `kid=A`
- WHEN config changes to issuer Y with the same cache path and Y is
  offline
- THEN the X cache is not loaded for Y
- AND a token signed by X’s `A` that claims `iss=Y` is rejected

### Requirement: Last-known-good survives bad refresh and disk faults

A fetch SHALL be published only when it is a JWKS object with at
least one usable verification key and no conflicting duplicate
`kid`s. A rejected fetch SHALL leave the prior set in memory and on
disk. Persist SHALL be tmp+fsync+rename in the auth directory.
Cache read/parse/permission/I/O failure SHALL NOT authenticate a
caller and SHALL NOT fail process start.

#### Scenario: Empty fetch does not wipe the set

- GIVEN persisted `{A}`
- WHEN a live fetch returns an empty key set
- THEN `{A}` remains the verification set
- AND a subsequent restart still verifies `A`

#### Scenario: Corrupt cache is not a bypass

- GIVEN a truncated or unreadable cache file
- WHEN the edge starts with the issuer down
- THEN hosted JWT verification fails closed
- AND the process still starts

### Requirement: Signer lookup is Mjolnir-owned and refresh is bounded

A Mjolnir-owned signer table SHALL be what JWT verification looks
up. Background refresh SHALL NOT stall verification of already-known
kids. After an empty offline start, refresh SHALL retry without
blocking boot. The HTTP adapter SHALL keep certificate verification.

#### Scenario: Known token verifies during a blocked refresh

- GIVEN persisted `{A}` and an in-flight refresh that does not return
- WHEN an otherwise-valid token signed by `A` is presented
- THEN it verifies without waiting for the refresh

### Requirement: Bootstrap uses the same persist contract

Host bootstrap SHALL seed `/var/lib/mjolnir/auth` using the same
issuer binding, validation, and atomic persist rules when the issuer
is reachable. Unreachable bootstrap SHALL NOT fail host bring-up.

#### Scenario: Reachable bootstrap seeds the cache

- GIVEN a fresh auth directory and a reachable issuer
- WHEN bootstrap runs
- THEN a bound, validated JWKS file exists at the auth path

#### Scenario: Negative verification still applies to cached kids

- GIVEN persisted `kid=A` for issuer I
- WHEN a token with `kid=A` has a bad signature, wrong `iss`, or
  expired `exp`
- THEN verification fails

#### Scenario: Failed persist of an added key

- GIVEN disk `{A}` and a validated fetch `{A,B}` whose persist fails
- WHEN a token signed by `B` is presented before restart
- THEN it verifies against the active set
- AND degraded durability is reported
- WHEN the process restarts with I unreachable
- THEN `B` is rejected and `A` still verifies

#### Scenario: Failed persist of a retirement

- GIVEN disk `{A,B}` and a validated fetch `{B}` whose persist fails
- WHEN a token signed by `A` is presented before restart
- THEN it is rejected (active set is `{B}`)
- WHEN the process restarts with I unreachable
- THEN `A` verifies again until a later successful persist of `{B}`

#### Scenario: Operator seed after empty boot

- GIVEN empty cache, issuer unreachable, and hosted verify fail-closed
- WHEN the operator places a valid bound JWKS file and restarts
- THEN that file is the serving set
