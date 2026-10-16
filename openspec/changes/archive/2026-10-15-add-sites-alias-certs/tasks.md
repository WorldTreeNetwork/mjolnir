# Tasks

- [x] `SecretStore.read_alias/1` distinguishes a missing file from an unreadable or unparseable one. `lookup_alias/1` stays a miss on every error.
- [x] `Mjolnir.Gateway.Classify` mirrors base `gateway.toml` plus `gateway.d` drop-ins, including the gateway's miss and skip rules.
- [x] `Gateway.Certs.ensure/2` skips the `[[domain]]` append when `domain: false`. The default stays append.
- [x] `Mjolnir.API.Certs` widens `ops.ensure` to 4 arguments, resolves app-then-alias, and renews with `domain: false` after an alias-index check that runs before Let's Encrypt.
- [x] `POST /api/certs/issue` dispatches the app path and the site path. `GET /api/certs` includes live site aliases and omits alias-only hosts when the index is unreadable, without failing the list.
- [x] Tests cover issue, renewal, classify vectors, the sites-token refusal, and a site-only `[[cert]]` still classifying as a route-table miss before and after a renewal pass.
- [x] `docs/guide/deploying-a-static-site.md` describes `mj cert issue` for a site alias. Leave the default-hostname section alone.
