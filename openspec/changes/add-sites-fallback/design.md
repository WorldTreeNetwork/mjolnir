# Design — sites fallback / miss path

**Status:** ACTIVE BUILD
**Change:** `add-sites-fallback`
**Rigor:** architecture

Not a new ADR. Unbound-name 307 stays `parked.rs`. This is the
**bound live site** miss path only.

## Pins

1. **Files win.** `ServeDir` 200/304 is the object. Fallback runs
   only on 404 from the snapshot tree.

2. **Explicit SPA beats snapshot 404.html.**
   `fallback = "index.html"` rewrites to `/index.html` at **200**
   even if `404.html` exists. Cache-Control is HTML revalidate
   (`max-age=0, must-revalidate`), not immutable.

3. **Snapshot 404.html without config is still custom 404.**
   Today's Hugo/static sites keep working. `fallback = "404.html"`
   is the same outcome, written down.

4. **`fallback = false` is empty 404.** No park chrome, no
   snapshot `404.html`. Status 404, original Host.

5. **Default chrome is park's file, not compiled HTML.** When none
   of 2–4 apply, the gateway reads the materialized
   `park.worldtree.network` snapshot's `404.html` (same
   `sites_root` layout as any other site) and returns those bytes
   at 404 with the **request** Host. No `Location`. If that file
   is missing, empty 404 — do not 307, do not interpolate
   `parked.rs`.

6. **Policy is a sibling of `current`, not a ServeDir path.**
   Publish/materialize writes
   `<fp>/<site>/fallback` (plain text: `index.html` | `404.html` |
   `false`) next to `current`, outside the snapshot tree. ServeDir
   never sees it. A file named `fallback` inside the snapshot is
   a site asset, not this policy.

7. **`[site].fallback` is the authoring surface.** `mjolnir.toml`
   unknown keys stay ignored; this key becomes known on Manifest
   and on `mj sites publish`. Older `mj` without the key still
   loads the file (HTTP-style). Hyphen `fall-back` is not an
   alias.

## Park lookup

Resolve `park.worldtree.network` the same way any Sites Host
resolves (alias → `(fp, site)` → `current`). Then
`current/404.html`. Cache that directory handle; it is not
per-request Elixir.

## Not this change

Replacing the unbound berth page. Deploying park's snapshot.
Elixir decrypt `Sites.Server` misses.
