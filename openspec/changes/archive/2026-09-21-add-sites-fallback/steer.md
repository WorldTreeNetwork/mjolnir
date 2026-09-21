# steer add-sites-fallback

**When.** 2026-09-20
**Bead.** `mjolnir-9bq.12` (child landing `mjolnir-9bq.12.2`)

Recorded on the parent bead; copied here so change has residue.

## Decided

- Default 404/error chrome is a **site we deploy** at
  `park.worldtree.network` (`404.html`, maybe 500 later), not
  compiled into the gateway.
- Override via `[site].fallback` as already designed on the bead.
- Path miss on a **LIVE** site must **not** 307 to park (that 307
  is for unbound hostnames). Serve park's `404.html` in place:
  same Host, status 404.

Order:

1. `[site].fallback = "index.html"` → 200 SPA rewrite
2. `fallback = "404.html"` or snapshot `404.html` → custom 404
3. `fallback = false` → empty 404
4. else → park.worldtree.network's deployed `404.html` body,
   status 404, original Host

## Feeds change

`add-sites-fallback`. Park body is a disk read of the park site's
materialized snapshot, not a redirect and not `parked.rs` HTML.
