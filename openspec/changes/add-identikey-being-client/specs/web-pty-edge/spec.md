## ADDED Requirements

### Requirement: Same-origin /term authenticates at auth.identikey.me

Unauthenticated `GET /term/:id` SHALL redirect the browser through
`https://auth.identikey.me/authorize` as a registered **public**
PKCE client (`subject_type=public`, `token_endpoint_auth_method=none`).
The authorization code SHALL be exchanged on the Mjolnir API origin.
The resulting ID token `sub` SHALL be the 64-lowercase-hex XID and
SHALL become `conn.assigns[:user_id]`. The hop SHALL set the existing
`mj_term` cookie. It SHALL NOT use `connect.identikey.io` / Keycloak
device-code. It SHALL NOT create an IdentiKey account on assertion.
Foreign-origin `/devterm*` SHALL continue to terminate on the trusted
edge (this requirement does not put a Mjolnir JWT in dashboard JS).

#### Scenario: Passkey opens /term

- GIVEN a friend with a registered passkey on a C2 identikey
  and a VM whose `owner_id` is that XID
- WHEN they open `/term/<id>` with no `mj_term` cookie
- THEN the browser completes WebAuthn at `auth.identikey.me`
- AND the PTY attaches with `user_id` equal to that XID
- AND the Mjolnir JWT is not held by a foreign-origin page

#### Scenario: Unknown passkey does not mint an identity

- GIVEN no stored C2 identity for the authenticator
- WHEN `/authorize` is attempted for the Mjolnir client
- THEN no identikey row is inserted
- AND `/term` does not set `mj_term`

#### Scenario: public sub is the XID

- GIVEN the Mjolnir client is registered `subject_type=public`
- WHEN the ID token is verified
- THEN `sub` is the 64-lowercase-hex XID
- AND it is not a pairwise `KDF(salt, xid, sector)` value
