# Design — offline hosted JWKS

**Status:** Proposed. ACTIVE BUILD. Revised 2026-09-24 after astra-arch-review advise-2.
**Change:** `add-offline-jwks`
**Bead:** `mjolnir-22ff.1`

## Problem

`Mjolnir.Auth.KeycloakStrategy` is started with `first_fetch_sync: true`
(`lib/mjolnir/application.ex`). JokenJwks fetches
`{issuer}/.well-known/jwks.json` (or Keycloak certs) before the
supervisor is ready. There is no on-disk last-known-good.

## Decision 1 — Disk first, boot always

Host files under `/var/lib/mjolnir/auth` (steer), directory `0700`,
files `0600`, created with those modes (not chmod-after-write). Path
must resolve outside `btrfs_root`; aliases into the data volume are
rejected at config load (process still starts; JWT verify stays
fail-closed). Live JWKS fetch is never on the start critical path.

## Decision 2 — Retention is issuer-set, not token-exp

v1 does not invent a numeric key TTL (steer). The trusted set is
exactly the `kid`s in the last **validated** JWKS document for this
issuer. `{A,B}` → `{B}` when a later validated fetch omits `A`; that
set is what restarts load. Token `exp` is a separate check on each
token. Operator withdraws trust by deleting the cache file for that
issuer, or by changing issuer (Decision 3). A kid the issuer still
publishes remains trusted for newly minted unexpired tokens — that is
the outage tradeoff; compromise recovery is “issuer drops the kid”
or “operator deletes the cache”.

## Decision 3 — Cache is bound to issuer + JWKS URL

On-disk document includes `issuer` and `jwks_url` (normalized:
trim trailing slash). Load rejects a file whose binding does not
match current config; boot continues; JWT verify fail-closed for
that issuer. A token signed by the previous issuer’s key but
claiming the new `iss` is rejected.

## Decision 4 — Validate before publish; keep last-known-good

A fetch is published only if it parses as JWKS, has at least one
usable verification key, and has no conflicting duplicate `kid`s.
Malformed, empty, or unsupported-only responses keep the prior set
in memory and on disk. Writes are tmp+fsync+rename in the auth dir.
Read/parse/permission/I/O failure of the cache is not an auth bypass
and not a boot failure. If a valid fetch is in memory but persist
fails, serve from memory and log degraded durability; next restart
uses the previous on-disk set.

## Decision 5 — Seam

A Mjolnir-owned signer table (not JokenJwks’ in-place map replace)
loads disk, then **replaces** itself with each later validated JWKS
document for this issuer (Decision 2 — not a union). Overlap is the
issuer publishing `{A,B}`. `{A}` → `{A,B}` → `{B}` is three
successful publications. The Joken hook looks up this table.
Background refresh is bounded and must not stall verification of
already-known kids. Mint TLS verification stays. Empty offline start
retries in the background until a validated fetch or operator seed.

## Decision 6 — Bootstrap

`scripts/` / host bootstrap (same path as other `/var/lib/mjolnir`
dirs) seeds the cache when the issuer is reachable, using the same
validate+bind+atomic persist rules. Unreachable bootstrap is
best-effort; the edge still starts.

Audience validation on hosted JWTs is an existing Token-module
gap (`skip: [:aud]`); not this change. Track separately.

## Decision 7 — Residual after advise-2 (R6–R8)

**Trusted set is the last validated issuer document.** Proposal
wording that “previously fetched unexpired keys stay valid” is
superseded: a kid remains trusted only while the issuer still
publishes it in the last **successfully persisted** (for restart)
or last **successfully validated in memory** (for the running
process) JWKS. Token `exp` is independent. Sequence `{A}` →
`{A,B}` → `{B}` must hold in the running table after each
successful publication, and after restart when that publication
also persisted.

**Operator withdrawal (v1):** stop the process, delete that
issuer’s cache file, start while the issuer is unreachable. After
that start, the in-memory table is empty for that issuer; hosted
JWT verify fails closed. Live in-process invalidation is not
promised. An in-flight fetch that began before the stop does not
survive it. An empty JWKS from the issuer is rejected (Decision 4)
and does not clear a good cache — issuer-side removal of the final
key is not enough; the operator must delete the file. An operator
seed (valid cache file placed on disk while the process is down)
becomes the serving set on **next start**. Placing a file under a
running process has no effect until restart or a later validated
fetch.

**Active vs persisted:** unknown-`kid` rejection uses the **active**
(memory) set. Durable retirement/addition for the next boot
requires a successful persist. If a valid fetch `{A,B}` is in
memory but persist fails, serve `{A,B}` now and log degraded
durability; restart reloads disk `{A}` so `B` stops verifying. If
a valid fetch `{B}` (retiring `A`) is in memory but persist fails,
serve `{B}` now (reject `A`); restart reloads disk `{A,B}` so `A`
verifies again until a later successful persist of `{B}`. Operator
recovery for an unpersisted retirement: stop, write or delete disk
to the intended set, start.
