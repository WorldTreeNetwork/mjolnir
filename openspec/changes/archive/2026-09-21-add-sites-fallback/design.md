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

7. **`[site].fallback` is the authoring surface.** `mj sites
   publish <dir>` reads `dir/mjolnir.toml`, then one parent
   `dir/../mjolnir.toml` (app root when publishing `dist/`).
   That parse is **site-only**: a file with just `[site]` is
   valid and MUST NOT require `start_command` / `port`.
   `Deploy.Manifest` for VM deploy is unchanged (those fields
   still required there). Unknown keys stay ignored.
   Hyphen `fall-back` is not an alias. Invalid known values
   refuse the publish.

8. **Durable source is a signed site policy record, not HEAD
   and not the snapshot manifest.** HEAD signing bytes stay
   as they are (mixed-version re-serialize). New record
   `sites/<name>/fallback` in SecretStore: `{fallback, sequence,
   identikey_fp, site_name, created_at, signature}`. Absent
   record = unset policy (steer steps 2/4). Older publishers
   write nothing. Policy is **site-wide** (not per snapshot).
   Materializer copies it to the sibling file in the same
   atomic window as flipping `current`. Rematerialize rebuilds
   the sibling from the store. Failed publish writes neither
   HEAD nor policy. Reset: publish with `fallback` omitted
   deletes the policy record. Rollback of HEAD without a new
   policy leaves policy as last successful write.

## Park lookup

Resolve `park.worldtree.network` via the existing alias →
`(fp, site)` → `current` path, then ServeFile `404.html` only
— never the park site's fallback chain. Canonicalize +
`sites_root` containment; escaping `current` is "park missing"
(empty 404).

Cache the resolved park **directory** with a **60s** success
TTL. Do not cache lookup failures longer than **5s** (so a
later publish becomes visible). Republish/prune/rebind are
visible after the success TTL at worst. No per-miss Elixir
round-trip on a warm cache.

## Fallback HTTP

- Missing explicit `index.html` or unreadable → empty 404, not
  200, not park.
- Missing explicit `404.html` → empty 404, not park.
- Invalid sibling policy bytes → empty 404 (fail closed).
- HEAD: same status and headers as GET, empty body.
- ServeDir 405 / 206 are not misses; do not rewrite them.
- SPA rewrite uses HTML revalidate Cache-Control even if the
  request path looks immutable (`/_app/immutable/...`).
- SPA 200 may 304 on index.html validators; do not 206 a rewrite.
- Keep br/gz precompression on fallback files.

## Not this change

Replacing the unbound berth page. Deploying park's snapshot.
Elixir decrypt `Sites.Server` misses. Changing HEAD or
snapshot-manifest signed field sets.
