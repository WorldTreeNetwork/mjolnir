# add-sites-alias-certs

> **ACTIVE BUILD**

Activated by the campaign grant on `mjolnir-uktt.2` ("activate and run", 2026-10-15). Dependency `add-site-cert-subject` is accepted and folded (`8c8390d`).

**Rigor:** change
**Bead:** `mjolnir-uktt.2.2`
**Capability:** site-certs

## Why

`mj cert issue` still looks up only a deployed app. A published site with a domain binding has no certificate path, so the public name cannot be HTTPS without an operator shell.

## What

Make the living `site-certs` spec true in the issuer, the gateway install, and the certificate list. The install flag defaults to today's apex append. A site alias and every renewal pass skip that append.

## Impact

- Capabilities: MODIFIED `site-certs` (parse-failure is unreadable, renewal does not re-apply the 409, list stays 200 when the alias index is unreadable). ADDED one fail-closed rule for an unclassifiable gateway config on the site path.
- ADRs: none (ADR 0013 stands)

## User journey & surfaces

No new UI because the outcome already reaches `mj cert issue <fqdn>` and `GET /api/certs`.

- **Working** — after publish and `mj domain set`, `mj cert issue blog.example.com` returns `fqdn`, `status`, and `not_after`. HTTPS on that name serves the snapshot. A `[[cert]]` is installed and no new `[[domain]]` is added.
- **Empty** — a name with no app and no live alias is `404 name_not_found`.
- **Failed** — an alias the gateway would already serve as local or Iroh is `409 host_routed_elsewhere` before HTTP-01. An unreadable alias index is `503 alias_index_unreadable`. An unclassifiable base `gateway.toml` on the site path is `503 gateway_config_unreadable`.
- **Off** — a `sites:publish` token is `403 insufficient_scope`.

## Out of scope

- App first-issue appending a short apex (`mjolnir-5ckn`)
- Default `*.sites` hostname (`mjolnir-9bq.10`)
- `GET /api/certs` temp-dir 500 (`mjolnir-kzrt`)
- Conduit web client, DNS-01, a gateway path split, merging sites and apps into one deploy
- Deploying or restarting `mjolnir.service`

## Preparation

Upstream artifact: ADR 0013 at `c93cda3`, living spec folded at `8c8390d`. Anchors re-read this session: `POST /api/certs/issue` (`router.ex`), `Mjolnir.API.Certs` 3-arity `ensure`, `Gateway.Certs.ensure_origin_ca` always calling `ensure_domain_block`, `SecretStore.lookup_alias/1` mapping every error to `:not_found`, gateway `classify` (`main.rs`) and drop-in merge (`config.rs`). Outcome: still valid. Authority: the recorded grant on `mjolnir-uktt.2`. Bounds: the four steer commitments plus the accepted advise bound (renewal never appends a missing `[[domain]]`, on any branch). Routine refinement, not a new architecture decision: a base gateway config that cannot be classified is `503 gateway_config_unreadable` on the site path only. Renewal does not consult that classification.
