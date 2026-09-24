# steer add-offline-jwks

**When.** 2026-09-24
**Depth.** explicit

## Decided
- JWKS persist dir: `/var/lib/mjolnir/auth`, `0600`, not btrfs (user, via key-custody menu)
  Why: same reason as escrow and blob cache — snapshots must not pin the keys.
- Last-known-good on reboot; unknown kid fail closed; overlap = keep unexpired previously fetched keys (auto)

## Amended after advise-2 (2026-09-24)

Overlap is the issuer publishing both keys in one JWKS. A later
validated document that omits a kid retires it. The auto “keep
unexpired previously fetched keys” wording is superseded so
Decision 2 / Decision 5 / the delta agree (`{A}` → `{A,B}` → `{B}`).
Numeric TTL remains skipped.

## Skipped
- Numeric rotation overlap window — still-unexpired is enough for v1

## Feeds change
Drop `first_fetch_sync` as a hard start dependency. Disk cache is the reboot path. Hosted `/term` and hosted `mj login` keep using the same JWTs.
