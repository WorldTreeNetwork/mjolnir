# Design — Mjolnir as public PKCE client of auth.identikey.me

Canonical: ADR
[`0011`](../../../docs/decisions/0011-honor-being.md) Decisions 1–2.

**Change:** `add-identikey-being-client`
**Bead:** `mjolnir-x97p.2`

## Problem

`/term` authenticates with Keycloak device-code. The hosted being
needs passkey-on-web at `auth.identikey.me`, with `sub` = XID.

## Decision 1 — authorization code + PKCE, not device-code

identikey-core grant_types are `authorization_code` and the
identikey-auth URN. No RFC 8628. wrug.3's device-flow cannot move
to this OP without a new grant. Browser `/term` is same-origin: a
302 to `/authorize` and a loopback-on-API-origin redirect is enough.

Redirect URI is a path on the Mjolnir API origin (the same host
that serves `/term`), e.g. `/auth/callback`. PKCE S256. Public
client (`none`). No client secret.

## Decision 2 — `subject_type=public`

`identikey-oidc::Client::new` defaults to pairwise.
`client_from_spec` never sets `subject_type`. Env-registered
clients would get `KDF(salt, xid, sector)` as `sub`, which is not
the 64-hex XID `authorize_vm` compares to `owner_id`.

`IDENTIKEY_CLIENTS` JSON gains `"subject_type": "public"` (and
optional `"subject_type": "pairwise"` default). The Mjolnir client
is public. Pairwise remains the default for unspecified clients.

## Decision 3 — issuer cutover

`MJOLNIR_AUTH_ISSUER=https://auth.identikey.me`. JWKS from that
discovery document. Rename or generalize `KeycloakStrategy` so the
module name is not a lie; verification stays Joken + JWKS, `iss`
match.

Existing VMs stamped with Keycloak `sub` (UUID-shaped
`owner_id`s on mimir today) will fail `uid == oid` for an XID
token. Friend has no such VMs. Duke's fleet is out of scope to
migrate in this change.

## Decision 4 — no account on assertion

`/authorize` passkey ceremony already refuses to insert identities
(folded `add-hosted-login-ui`). Keep that. A friend without a C2
passkey does not get a hosted being by visiting `/term`.
