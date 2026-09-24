# add-offline-jwks

> **ACTIVE BUILD**

Bead `mjolnir-22ff.1`. Steer 2026-09-24.

**Rigor:** change (sensitive)

**Preparation (2026-09-24 /run):** still valid (advise-4 accept, contract hashes in that review). Upstream: existing `KeycloakStrategy` + `JokenJwks` hook `match_signer_for_kid/2`. Authority: 22ff campaign. Ready to act.

## Why

Elixir starts `Mjolnir.Auth.KeycloakStrategy` with `first_fetch_sync:
true`. A reboot while `auth.identikey.me` is unreachable fails boot,
so hosted JWTs cannot be checked even when they are unexpired and the
keys were already known. Direct-auth fallback does not help a client
that already holds a hosted credential.

## What

- Persist last-known-valid JWKS under `/var/lib/mjolnir/auth`, mode
  `0600`, outside `btrfs_root`.
- Boot from that cache; live fetch is opportunistic, not a start
  dependency.
- Unknown `kid` fails closed. Rotation overlap is the issuer
  publishing both keys in one JWKS (`{A,B}`). A later validated
  document that omits `A` retires `A`; the edge does not keep
  omitted kids just because their tokens are unexpired.
- Provision at bootstrap when the issuer is reachable.

## Impact

- Capabilities: ADDED `edge-auth`
- ADRs: none (cite `0012-direct-edge-auth` from `add-edge-op-keys`)

## User journey & surfaces

No new UI because `mj login` (hosted) and `/term` already present
hosted JWTs. This change is how the edge verifies them after reboot.

- **Working (after act)** — stop the hosted OP, reboot the edge,
  present an unexpired hosted ID token → 200 on an authenticated
  route.
- **Empty** — no JWKS on disk and issuer down → boot continues
  without JWT verify; tokens fail closed until a fetch succeeds.
- **Failed (today)** — `first_fetch_sync: true`; JWKS supervisor
  crashes or blocks start when the issuer is down.
- **Off** — no `:issuer` configured; no JWKS child (unchanged).

## Out of scope

- Direct challenge/sign/response — `add-direct-challenge`
- Edge operational keys — `add-edge-op-keys`
- `mj login --direct` / fallback matrix — `add-mj-login-modes`
- `/term` IdP choice — stays `auth.identikey.me` (`web-pty-edge`)
- Keycloak UUID `owner_id` migration
