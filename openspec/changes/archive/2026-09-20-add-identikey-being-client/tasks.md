# Tasks

- [x] identikey-core: `ClientJson` + `client_from_spec` honor
      `subject_type` (`public` | `pairwise`, default pairwise)
- [x] identikey-core: register Mjolnir public PKCE client on the
      live OP (`IDENTIKEY_CLIENTS` JSON, `subject_type=public`,
      redirect `https://api.vm.worldtree.network/auth/callback`)
- [x] Mjolnir: `/auth/login` starts authorization-code + PKCE
      (replace Keycloak device-code)
- [x] Mjolnir: `/auth/callback` exchanges code, sets `mj_term`,
      redirects to sanitized `/term/:id`
- [x] Mjolnir: JWKS from `{issuer}/.well-known/jwks.json` when
      not Keycloak; `MJOLNIR_AUTH_ISSUER` / `_CLIENT_ID` / `_REDIRECT_URI`
- [x] Tests: unauthenticated `/term` 302s to login; `/auth/login`
      302s to OP authorize with `client_id` + `code_challenge`;
      callback sets `mj_term`
- [x] Live: confirm assertion does not insert an identikey account
      (already the OP contract; verify on auth.identikey.me)

Handoffs (not this change):

- `add-vm-git-subkey` — `mjolnir-x97p.3`
- `add-honor-dev-preview` — `mjolnir-x97p.5`
