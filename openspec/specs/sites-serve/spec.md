# sites-serve

What is built. Seeded by
[`add-sites-fallback`](../../changes/archive/2026-09-21-add-sites-fallback/proposal.md)
on 2026-09-21. No ADR: the unbound-hostname 307 to
`park.worldtree.network` stays in `parked.rs` and is untouched by
this capability.

## Purpose

The **bound live site** miss path. Once a request Host has resolved
to a materialized Sites snapshot, a path miss belongs to that Host:
`ServeDir` 404 chooses a body from an explicit `[site].fallback`
policy, the snapshot's own `404.html`, or the deployed
`park.worldtree.network` site's `404.html` — and never redirects.
SPA deep links (`GET /about`) become a 200 rewrite to
`/index.html` when the operator asks for it; existing files always
win. Default 404 chrome is a *deployed site's* file, not HTML
compiled into the gateway.

Policy travels as its own identikey-signed SecretStore record and
lands as a sibling of the site's `current` symlink, so it is
neither a served snapshot path nor a change to the HEAD/manifest
signing bytes.

## Requirements

### Requirement: Bound-site misses stay on the request Host

A path miss on a Host that already resolved to a materialized
Sites snapshot SHALL NOT 307 (or otherwise redirect) to
`park.worldtree.network`. Unbound-hostname fallthrough MAY still
307. The miss response SHALL use the original request Host.

#### Scenario: Live deep link does not redirect to park

- GIVEN a bound site at `blog.example` with a materialized snapshot
- WHEN a client GETs `https://blog.example/about`
- AND that path is not a file in the snapshot
- THEN the response is not 307
- AND `Location` does not name `park.worldtree.network`

#### Scenario: Unbound name still parks

- GIVEN a Host with no alias and apex fallthrough `parked`
- WHEN it is requested
- THEN the existing unbound 307 to `park.worldtree.network` still
  applies

### Requirement: Miss fallback order

After `ServeDir` returns 404 for a bound materialized site, the
gateway SHALL choose the body in this order:

1. Site policy `index.html` → serve snapshot `/index.html` with
   status 200
2. Site policy `404.html`, or a snapshot file `404.html` when
   policy is unset → that file with status 404
3. Site policy `false` → empty 404
4. Else the materialized park site's `404.html` with status 404;
   if that file is missing, empty 404

A 200, 304, 206, or 405 from `ServeDir` SHALL skip this order.

If policy selects `index.html` or `404.html` and that file is
missing or unreadable, the gateway SHALL return empty 404 — not
200, not park chrome. Invalid policy bytes on disk SHALL be
empty 404. HEAD SHALL use the same status and headers as GET
with an empty body. An SPA rewrite SHALL use HTML revalidate
Cache-Control even when the request path is under
`/_app/immutable/`.

#### Scenario: SPA rewrite

- GIVEN `[site].fallback = "index.html"`
- AND snapshot `/index.html` exists
- AND `/about` is not a file
- WHEN a client GETs `/about`
- THEN the status is 200
- AND the body is `/index.html`

#### Scenario: Snapshot 404.html without config

- GIVEN no `[site].fallback`
- AND the snapshot contains `404.html`
- WHEN a client GETs a missing path
- THEN the status is 404
- AND the body is that `404.html`

#### Scenario: Explicit empty 404

- GIVEN `[site].fallback = false`
- WHEN a client GETs a missing path
- THEN the status is 404
- AND the body is empty
- AND snapshot `404.html` is not served

#### Scenario: Park chrome in place

- GIVEN no `[site].fallback`
- AND the snapshot has no `404.html`
- AND park's materialized `404.html` exists
- WHEN a client GETs a missing path on the live Host
- THEN the status is 404
- AND the body is park's `404.html`
- AND the response Host is the live site's Host

#### Scenario: Existing file wins

- GIVEN `[site].fallback = "index.html"`
- AND `/logo.png` exists in the snapshot
- WHEN a client GETs `/logo.png`
- THEN the status is 200
- AND the body is that file, not `index.html`

### Requirement: Fallback policy is not a served snapshot path

`[site].fallback` SHALL be authored in `mjolnir.toml`. The running
policy SHALL live next to the site's `current` symlink, not as a
path inside the snapshot tree `ServeDir` serves. A snapshot file
named `fallback` SHALL be an ordinary asset.

#### Scenario: Policy file is not GET-able as a page

- GIVEN a site with policy `index.html`
- WHEN a client GETs `/fallback`
- THEN the response is the miss order, not the policy text
  (unless the snapshot itself contains a file `fallback`)

#### Scenario: Explicit SPA target missing

- GIVEN `[site].fallback = "index.html"`
- AND snapshot `/index.html` is absent
- WHEN a client GETs `/about`
- THEN the status is 404
- AND the body is empty
- AND park chrome is not served

#### Scenario: HEAD of an SPA miss

- GIVEN `[site].fallback = "index.html"`
- AND snapshot `/index.html` exists
- WHEN a client HEADs `/about`
- THEN the status is 200
- AND the body is empty
- AND Content-Type matches GET of `/index.html`

### Requirement: Fallback policy is a signed site record

`[site].fallback` SHALL travel as its own identikey-signed
SecretStore record (`sites/<name>/fallback`), not as a new field
on HEAD or on the snapshot manifest (those signing byte sets
SHALL NOT change). An absent record SHALL mean unset policy.
Materialize SHALL write the sibling file from that record in the
same atomic window as flipping `current`. Rematerialize SHALL
rebuild the sibling from the store. A failed publish SHALL leave
the previous HEAD and policy in place.

#### Scenario: Older publisher

- GIVEN a client that does not write a policy record
- WHEN the site is served
- THEN policy is unset
- AND snapshot `404.html` / park chrome still apply

#### Scenario: Rematerialize restores policy

- GIVEN a signed policy record `index.html`
- AND the materialized tree was deleted
- WHEN materialize runs
- THEN the sibling policy file is `index.html` again
- AND `GET /about` is 200 `/index.html`

### Requirement: Park chrome cache is bounded

A successful resolve of park's snapshot directory MAY be reused
for at most 60 seconds. A failed resolve SHALL NOT be reused for
more than 5 seconds. Park ServeFile SHALL NOT run the park site's
own fallback order. A `current` symlink that escapes `sites_root`
SHALL be treated as park missing.

#### Scenario: Park published after a miss

- GIVEN park was missing
- AND a live miss returned empty 404
- AND park's `404.html` is then materialized
- WHEN more than 5 seconds have passed
- AND another miss occurs
- THEN the body is park's `404.html`
