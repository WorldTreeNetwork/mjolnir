# add-site-cert-subject

> **ACTIVE BUILD**

Bead `mjolnir-uktt.2.1`. Steer 2026-10-15. Campaign `mjolnir-uktt.2`.

**Rigor:** architecture

**Preparation (2026-10-15):** still valid. Inbound is the steer on `mjolnir-uktt.2.1` plus the live cert and sites paths cited below. No living `site-certs` spec. `sites-serve` is the miss-body policy and is untouched. Authority: "activate and run" on `mjolnir-uktt.2`.

## Why

`mj cert issue <fqdn>` issues an HTTP-01 certificate only when `Deploy.Registry` has that custom domain. A published IdentiKey Site binds the same kind of name with `mj domain set`, stores it as a signed alias, and then `POST /api/certs/issue` returns `404 app_not_found`. The gateway already answers `/.well-known/acme-challenge/` before routing, and SNI already selects a `[[cert]]`. The app installer also appends a `[[domain]]` apex. A new apex with no fallthrough parses as Iroh, and that disposition never reaches the sites resolver, so reusing the installer unchanged would mint a certificate and stop serving the snapshot.

Steer (2026-10-15): any `vms:spawn` login may issue when a live alias exists. A site-only install writes `[[cert]]` and does not add `[[domain]]`. An app custom domain owns the whole host. Renewal re-resolves the host and reinstalls the certificate. It does not append a `[[domain]]` that is not already present, on any branch, and an unreadable alias index fails that pass instead of counting as a miss. If the host would already classify as a local route or an Iroh dial, issuance refuses with `409 host_routed_elsewhere` before HTTP-01.

## What

- Add capability `site-certs`.
- Lookup order: app custom domain, then a live site alias, then `404 name_not_found`.
- App hit keeps the owner check. The app's first issue may still add `[[domain]]`. Renewal does not.
- Site-only hit: same HTTP-01 one-shot and `[[cert]]` only, unless the host would classify as Local or Iroh, which is `409 host_routed_elsewhere` before HTTP-01.
- An unreadable alias index is `503 alias_index_unreadable`, not a miss.
- Renewal uses that same classification and reinstalls the certificate. It does not append a `[[domain]]` that is not already present, on any branch. An app's first issue may still add an apex.
- `GET /api/certs` includes live site-alias hosts for any login that can list certificates.
- ADR `docs/decisions/0013-site-alias-certs.md` records the rules. Implementation is `add-sites-alias-certs`.

## Impact

- Capabilities: ADDED `site-certs`
- ADRs: will add `docs/decisions/0013-site-alias-certs.md`

## User journey & surfaces

A person who has published a site and bound a domain, from `mj cert issue` and a browser. No new screen.

- **Working** — `mj cert issue blog.example.com` returns `fqdn`, `status`, and `not_after`, with no PEM. `https://blog.example.com/` returns the published snapshot.
- **Empty** — a name with no app and no live alias is `404 name_not_found`.
- **Failed (today)** — the same command is `404 app_not_found`. TLS fails before the sites resolver, or an operator runs `mjolnir-gateway cert issue` on the host.
- **Off** — a `sites:publish` token is `403 insufficient_scope`. A wildcard is `400 wildcard_not_supported`. A name an app already owns stays on the app path, including `404 app_not_found` when the caller does not own that app. A site name the gateway would already classify as Local or Iroh is `409 host_routed_elsewhere`. An unreadable alias index is `503 alias_index_unreadable`.

## Out of scope

- Installing the certificate and changing the issuer — `add-sites-alias-certs` (`mjolnir-uktt.2.2`)
- Rewriting `docs/guide/deploying-a-static-site.md` — same follow-on, once the command works
- Merging sites and apps into one deploy pipeline
- A gateway path split that sends some paths to a site and others to a VM
- DNS-01, or holding the owner's DNS credentials
- The Conduit web client
- A default `*.sites` hostname — `mjolnir-9bq.10`
- `GET /api/certs` temp-dir crash — `mjolnir-kzrt`
- Letting a `sites:publish` token issue certificates
