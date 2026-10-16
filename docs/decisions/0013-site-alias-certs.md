# ADR 0013: Site aliases are certificate subjects

**Status:** Accepted

## Decision

`mj cert issue <fqdn>` has two subjects. An app custom domain stays an app. A live IdentiKey Site alias is a second subject of the same HTTP-01 issuer. A site stays a signed snapshot with no VM. The command does not change.

## Rules

1. **Authority.** Any caller who already passed `vms:spawn` may issue when a live alias exists. There is no per-alias owner stamp. A `sites:publish` token is `403 insufficient_scope` and does not issue. This is the 2026-10-15 steer. Open issuance spends the host Let's Encrypt quota on any published alias. The alias is already a public routing record. That quota is the accepted cost.

2. **Collision.** If `Deploy.Registry` has this custom domain, the app owns the whole host. The site path does not run. A caller who does not own the app gets `404 app_not_found`. `app_not_found` versus `name_not_found` tells a non-owner that some app holds the name. Custom domains are already public in DNS. That existence oracle is an accepted cost.

3. **Install.** A site-only subject writes `[[cert]]` for that exact host and does not add a `[[domain]]` block. An apex already present stays. This does not delete apexes. An app's first issue may still add an apex.

   Before HTTP-01 on the site path, classify the host as the gateway would. `Local` or `Iroh` returns `409 host_routed_elsewhere` and does not call Let's Encrypt. `Reject` and `Parked` still reach the sites resolver, so those issue. A `[[route]]` or gateway `[[alias]]` for that subdomain is `Local` or `Iroh` and refuses. An existing apex with fallthrough `none` or `parked`, and no route for that subdomain, still issues, and the apex is left as it is.

   `add-sites-alias-certs` mirrors `gateway.toml` in Elixir with the gateway's defaults: a missing fallthrough is Iroh; a `[[alias]]` resolves under any fallthrough; a bare apex without an empty-subdomain route is `EmptySubdomain`; host match is longest-suffix. It pins those with test vectors shared with the gateway `classify` tests. It does not add a gateway control call.

4. **Renewal.** The daily pass reinstalls at most one due certificate. It does not append a `[[domain]]` that is not already in the file, on any branch: app, site, or stranger. A hand-installed name such as `zine.identikey.io` still renews. If its apex is already declared, that block stays. Renewal does not create one that was missing.

   This bound comes from the 2026-10-15 architecture advise (S1), not from the steer sentence that said a stranger keeps today's ensure. Today's ensure also adds a missing apex. The bound keeps the renewal and drops only the append. An app whose apex was later deleted is not given that apex back by the timer. The next app issue can add it.

   Renewal does not re-apply the 409. A site certificate whose host later classifies as Local or Iroh keeps renewing.

   An unreadable alias index is an error, not a miss. A missing file is a miss. A readable file that does not parse is unreadable. Issue returns `503 alias_index_unreadable` and does not call Let's Encrypt. Renewal installs nothing and adds no `[[domain]]`.

5. **List.** `GET /api/certs` omits PEMs. The operator sees every certificate. Any other caller who passed the list scope sees certificates for app domains they own, plus every certificate whose host is a live site alias. A hand-installed host that is not a live alias stays operator-only. If the alias index is unreadable, the list omits alias-only hosts and still returns 200 with the owned app hosts. It does not fail the whole list.

## Why the apex is the hazard

`Mjolnir.Gateway.Certs.ensure/2` appends `[[domain]] suffix = <last two labels>` when that suffix is absent. The gateway parses a missing fallthrough as Iroh. `classify` then returns Iroh for an unknown subdomain and never consults the sites resolver. Sites lookup runs for Parked and Reject. SNI selects `[[cert]]` without an apex. HTTP-01 is served before classify.

A site name works because its apex is undeclared, so classify returns `DomainMismatch` and the resolver serves the snapshot. Adding `example.com` as an Iroh apex to certify `blog.example.com` would stop serving that site, and would take a sibling such as `docs.example.com` off the resolver too.

## Lookup

Normalize the way app custom-domain lookup already does: trim, strip one trailing dot, downcase. A wildcard is `400 wildcard_not_supported` before either lookup. A tombstone is a miss.

1. App custom domain → the existing owner check. First issue may add `[[domain]]`.
2. Else a live site alias → classify, then HTTP-01 with domain insertion off.
3. Else `404 name_not_found`.

## Install seam

`Gateway.Certs.ensure/2` gains a flag that defaults to today's behaviour and can skip the apex append. Site-only issuance passes it. An app's first issue does not. Renewal passes it on every branch. `Mjolnir.API.Certs` ops `ensure` widens past three arguments so tests can see the flag. PEMs stay on the host. The one-shot stays `systemd-run` as user `mjolnir`.

A site-only `[[cert]]` does not change classification. The follow-on test is that such a config still classifies as `Reject(DomainMismatch)` before and after a renewal pass.

## What this does not do

- No merged deploy pipeline.
- No path split on one host.
- No DNS-01 and no customer DNS credentials.
- No new client flag.
- No change to the sites-serve miss policy.
- No default `*.sites` hostname.
- The issuer, the ensure flag, and the tests land in `add-sites-alias-certs` (`mjolnir-uktt.2.2`).

## Residual

App first issue still appends the last two labels, even when the configured apex is longer (for example `apps.example.com`). `:gateway_apexes` can also drift from `gateway.toml`. Either can still capture a sibling site alias. That is pre-existing app-path behaviour, and this change does not widen it. Tracked as `mjolnir-5ckn`.
