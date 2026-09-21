## ADDED Requirements

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

A 200 or 304 from `ServeDir` SHALL skip this order.

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
