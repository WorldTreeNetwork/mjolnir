# add-sites-fallback

> **ACTIVE BUILD**
>
> Steered 2026-09-20 on `mjolnir-9bq.12`. Activated by `/intention:run`
> leftover grant 2026-09-21. Bead `mjolnir-9bq.12.2`.

**Rigor:** architecture

A path miss on a **live** bound site must stay on that Host. The
307 to `park.worldtree.network` is only for unbound names
(`parked.rs`). Default 404 chrome is a **deployed** park site's
`404.html`, not HTML compiled into the gateway.

## Why

`ServeDir` misses always serve the snapshot's `404.html` at status
404 (`sites_serve.rs`). Client-side routers 404 on every deep
link. Pages/Netlify default is a 200 rewrite to `index.html`.
Operators need an explicit `[site].fallback` and a shared 404
chrome that is itself a site.

## What

- Capability `sites-serve` (ADDED).
- Miss order (steer):
  1. `[site].fallback = "index.html"` → 200 SPA rewrite
  2. `fallback = "404.html"` **or** snapshot `404.html` → custom 404
  3. `fallback = false` → empty 404
  4. else → park.worldtree.network's materialized `404.html` body,
     status 404, **original Host**
- Existing files still win.
- Parse `[site].fallback` in `mjolnir.toml` (unknown keys stay
  ignored; this key becomes known).
- Policy reaches the gateway as a sibling of `current`, not a
  file inside ServeDir.

## Impact

- Capabilities: ADDED `sites-serve`
- ADRs: none (routing 307 for unbound hosts stays `parked.rs`)

## User journey & surfaces

Duke, a published site, `GET /about` on the live Host.

No new UI because `mjolnir.toml` and the gateway Host path already
exist.

- **Working (after)** — Vite SPA with `fallback = "index.html"`:
  `GET /about` is 200 and `index.html`. Hugo with snapshot
  `404.html`: `GET /missing` is 404 and that body. A live miss
  never 307s to park.
- **Empty** — `fallback = false`, or park site not materialized:
  empty 404, still that Host.
- **Failed (today)** — every miss is snapshot `404.html` at 404;
  no SPA rewrite; no park body in place.
- **Off** — park the change; today's snapshot-404-at-404 remains.

## Out of scope

- Unbound-hostname 307 / compiled berth page in `parked.rs`
  (except it MUST NOT fire on a live site miss)
- Authoring and publishing the park site itself
- 500 chrome
- Elixir `Sites.Server` decrypt path (pre-materialize fallback)
