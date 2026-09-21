# Tasks — add-sites-fallback

- [ ] Parse `[site].fallback` in `mjolnir.toml` (`index.html` |
      `404.html` | `false`); persist as sibling of materialized
      `current`
- [ ] Gateway miss path: SPA 200 / snapshot-or-config 404.html /
      empty 404 / park body at 404, original Host
- [ ] Existing snapshot files still 200; live miss never 307s to park
- [ ] Tests: Vite-style `GET /about` → 200 index.html; Hugo
      `404.html` → 404 body; `fallback = false` empty 404; park
      file in place when no policy and no snapshot 404.html
- [ ] Docs: `mjolnir.toml` `[site].fallback` and the park default

## Owed from architecture advise — 2026-09-21

- [ ] R1: Pin TOML discovery, site-only parsing, authenticated policy transport,
      durable source, mixed-version defaults, and site-versus-snapshot ownership;
      specify reset, publish failure/concurrency, rollback, and rematerialization
      semantics with end-to-end and lifecycle scenarios.
- [ ] R2: Pin park cache scope and refresh/recovery on late publish, republish,
      prune, and alias rebind; specify lookup failure and containment behavior
      with tests, without recursive fallback or per-miss backend lookup.
- [ ] R3: Pin missing/unreadable explicit targets and invalid policy handling;
      specify HEAD, conditional/range, compression, and fallback cache behavior
      with focused tests, preserving responses that are not snapshot misses.
- [x] Fresh architecture advise after R1–R3 contract amendments; reference
      `reviews/2026-09-21-advise.md` and the reconciled contract `9b48f63`;
      accepted by `astra-arch-review` in `reviews/2026-09-21-re-advise.md`.
