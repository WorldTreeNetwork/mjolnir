# Tasks

- [ ] identikey-core: `ClientJson` + `client_from_spec` honor
      `subject_type` (`public` | `pairwise`, default pairwise)
- [ ] identikey-core: register Mjolnir public PKCE client
      (`IDENTIKEY_CLIENTS` or `IDENTIKEY_CLIENT_ID`) with
      `subject_type=public`, redirect = API-origin `/auth/callback`
- [ ] Mjolnir: `/auth/login` starts authorization-code + PKCE
      against `auth.identikey.me` (replace Keycloak device-code)
- [ ] Mjolnir: `/auth/callback` exchanges code, sets `mj_term`,
      redirects to sanitized `/term/:id`
- [ ] Mjolnir: `MJOLNIR_AUTH_ISSUER=https://auth.identikey.me`;
      JWKS verify (generalize `KeycloakStrategy`)
- [ ] Tests: unauthenticated `/term` 302s to the OP authorize URL
      with `client_id`, `code_challenge`, `redirect_uri`; callback
      with a public `sub` (64-hex) assigns `user_id` to that XID
- [ ] Confirm assertion does not insert an identikey account

Handoffs (not this change):

- `add-vm-git-subkey` — `mjolnir-x97p.3`
- `add-honor-dev-preview` — `mjolnir-x97p.5`
