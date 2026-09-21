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
