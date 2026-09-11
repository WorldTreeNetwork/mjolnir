# add-identikey-being-client

> **PENDING**

Bead `mjolnir-x97p.2`. Steer + ADR 0011: passkey at
`auth.identikey.me` opens wrug `/term`. grok is not an IdentiKey
OIDC client. Fable: `subject_type=public` so `sub` is the 64-hex
XID (`owner_id` equality).

**Rigor:** change

## Why

`/term` still starts a Keycloak device-code login
(`Mjolnir.Auth.Login`, issuer `connect.identikey.io`). identikey-core
already serves passkey `/authorize` at `auth.identikey.me`. The
hosted being cannot log in until Mjolnir is a **public** PKCE client
of that OP and `/term` completes WebAuthn instead of Keycloak.
`Client::new` defaults to pairwise; pairwise `sub` would break
`owner_id == XID`. identikey-core has no device_code grant — do not
keep the wrug.3 device-flow against this OP.

## What

- Register a public PKCE client (`token_endpoint_auth_method=none`,
  `subject_type=public`) for Mjolnir on `auth.identikey.me`.
- Extend identikey-core `IDENTIKEY_CLIENTS` / `ClientJson` so
  `subject_type` can be `public` (today every env-registered client
  is pairwise).
- Replace `/auth/login` device-code with authorization-code + PKCE
  against `https://auth.identikey.me`. Redirect lands on the API
  origin, sets `mj_term`, continues to `/term/:id`.
- Point `MJOLNIR_AUTH_ISSUER` at `https://auth.identikey.me`. Verify
  ID tokens via that OP's JWKS (today `Mjolnir.Auth.KeycloakStrategy`).
- Assertion does not create accounts.

## Impact

- Capabilities: MODIFIED `web-pty-edge` (same-origin `/term` IdP).
  identikey-core `oidc-provider` gains `subject_type` on env clients
  (work in that repo; contract below).
- ADRs: none new (0011 already accepted). Existing Keycloak `sub`
  `owner_id`s on mimir will not match after the issuer move. Fine
  for the friend (no prior VMs). Duke's existing VMs stay Duke-owned
  under the old `sub` until re-spawned.

## User journey & surfaces

Friend (or Duke with a passkey on that XID) opens
`https://<api-origin>/term/<vm-id>`.

- **Working (after act)** — unauthenticated `/term` 302s to
  `https://auth.identikey.me/authorize?...` (public client, PKCE,
  `subject_type=public`). Passkey assertion. Callback sets `mj_term`.
  PTY attaches. `owner_id` is the 64-hex XID.
- **Empty** — no passkey on that XID → `/authorize` does not mint
  an account.
- **Failed (today)** — `/term` device-codes Keycloak
  (`connect.identikey.io`). identikey-core is unused for `/term`.
- **Off** — `MJOLNIR_AUTH_ISSUER` left on Keycloak; hosted being
  cannot bind `owner_id` to an XID.

## Out of scope

- grok OIDC / `GROK_OIDC_ISSUER` — ADR 0011 Decision 2
- RFC 8628 device_code on identikey-core
- `add-vm-git-subkey` (`mjolnir-x97p.3`)
- `add-honor-dev-preview` (`mjolnir-x97p.5`)
- Growing Keycloak
- Re-owning Duke's existing Keycloak-`sub` VMs
