# Deploying a Static Site

How a directory of HTML/CSS/JS becomes a live website on **IdentiKey Sites** —
no microVM, no `mj deploy`, no Node process. You build the site on your laptop
(or in CI), then upload the output directory. The host stores a signed snapshot
and the gateway serves the files.

> **TL;DR** — From the project that *has the site*, not from this repo:
>
> ```bash
> mj login                                          # once
> mj sites keygen --out ~/.config/mjolnir/identikey.json   # once; prints fingerprint
> FP=…                                              # the fingerprint keygen just printed
>
> npm run build                                     # or hugo / astro build / …
> mj sites publish ./dist \
>   --identikey-fp "$FP" \
>   --site my-site \
>   --keypair-file ~/.config/mjolnir/identikey.json \
>   --sequence "$(date +%s)000"
> ```
>
> Then bind a domain (`mj domain set my-site blog.example.com --keypair-file ~/.config/mjolnir/identikey.json`), point DNS at the gateway, and get a cert (operator step today — `mj cert issue` is app-only). The flags are too many; see [Friction, and easier ways](#friction-and-easier-ways).

If you need a *running process* (SvelteKit `adapter-node`, a database, secrets),
stop here and use [Deploying a Web App](deploying-an-app.md) instead. Sites is
for **already-built files**.

---

## What you're actually doing

```
  your project (any directory)
      │
      │  your static generator (vite / astro / hugo / 11ty / …)
      ▼
  ./dist  (or ./build, ./public, ./_site — whatever the tool emits)
      │
      │  mj sites publish   ← encrypt + sign + upload from the laptop
      ▼
  signed snapshot on the Mjolnir host
      │
      │  materialize to plaintext on disk
      ▼
  gateway ServeDir  ──►  https://your-domain
```

Three properties that are easy to miss:

1. **The source tree never leaves your machine as source.** Only the built
   files are uploaded. Build locally (or in CI), publish the output.
2. **Every publish is an immutable snapshot.** Updating the site is a new
   snapshot plus a signed HEAD pointer. Previous snapshots stay addressable
   until retention expires (default: keep 5).
3. **The snapshot is signed by an IdentiKey.** That keypair is the proof of
   ownership. Lose it and you cannot publish the next version under the same
   identity. It is not the same thing as `mj login`.

Sites is **not** `mj deploy`. `mj deploy` tars a source tree, builds it *on
the host* inside a microVM, and boots a service. Sites never boots a VM.

---

## 0. One-time setup

You need the `mj` CLI, pointed at a Mjolnir server, and an IdentiKey.

### CLI and login

Same as [Getting Started](getting-started.md#0-one-time-setup):

```bash
# From a clone of this repo, if you don't have `mj` yet:
./scripts/build-client.sh --install

mj login --api https://api.vm.worldtree.network
mj status
```

`mj login` stores a JWT under `~/.config/mjolnir/`. That token is what
authorizes the *upload*. It is **not** what signs the site.

### Publishing identity

```bash
mj sites keygen --out ~/.config/mjolnir/identikey.json
```

Prints a **fingerprint** (base58) to stdout. Save it; every later command
asks for `--identikey-fp`. The file is `0600`. Treat it like an SSH key:
back it up, do not commit it, do not put it in the site's git repo.

`--out` defaults to `./identikey.json` (cwd). Do not accept that default
from a project directory — it will land in git. Always pass
`~/.config/mjolnir/identikey.json`.

The Mix task `mix mjolnir.publish` auto-creates that same path on first
use. `mj sites keygen` does **not**. You have to run it.

### Confirm the server will accept you

Publishing talks to the public API with the JWT from `mj login`. That is
enough for a human at a laptop.

CI needs a **sites token** instead — a credential that can only publish,
bound to one fingerprint (and optionally one site name). An operator mints
it *on the Mjolnir host*:

```bash
# on the host, as root, in /opt/mjolnir
mix mjolnir.sites.token create \
  --identikey-fp <fp> \
  --site my-site \
  --expires-in 90d \
  --description "ci for my-site"
```

The secret is shown once. In CI:

```bash
export MJOLNIR_TOKEN=mjsk_…
```

A sites token is checked *before* the localhost bypass, so presenting one
never silently upgrades to full control-plane access.

---

## 1. Build the site (in the project directory)

Do this in the repo that *has the site*, with whatever that project already
uses. Sites does not run your build.

| Tool | Typical output dir |
|---|---|
| Vite / VitePress | `dist/` |
| Astro (`output: 'static'`) | `dist/` |
| Hugo | `public/` |
| Eleventy | `_site/` |
| SvelteKit `adapter-static` (prerendered) | `build/` |
| Next `output: 'export'` | `out/` |
| Plain HTML | the folder itself |

Check that the folder contains `index.html` at the root of *what you will
publish*. If the generator nests the site (`dist/my-site/index.html`),
publish the inner directory, not the wrapper.

```bash
cd ~/work/my-site
npm run build          # or hugo, astro build, …
ls dist/index.html     # must exist
```

### What the publisher will and will not do

- Walks every regular file recursively. Dotfiles are included.
- Does **not** honor `.gitignore`. The input is a build output; those are
  usually gitignored as a whole.
- Does **not** rewrite SPA routes. A miss is a 404. Directory URLs get
  `index.html` (`/about/` → `/about/index.html`). Extensionless client-side
  routers (`/about` with no file) 404 unless you prerendered that path.
- A `404.html` in the snapshot is served on miss, with a 404 status.
- Per-file upload limit is **64 MiB**. Larger files are rejected.
- Symlinks: skip them in the source. Do not rely on `node_modules` links
  or `dist → somewhere-else`.

If the site is a client-rendered SPA with no prerender, Sites is the wrong
fit unless you also emit a real HTML file per route. Use `adapter-static`
(or equivalent) with prerender, or [deploy the app](deploying-an-app.md).

---

## 2. Publish the output directory

Still in the project directory. `mj` talks to the API you logged into; it
does not care that this isn't the Mjolnir repo.

```bash
# $FP is the fingerprint `mj sites keygen` printed. Keep it next to the key.
# Sequence must strictly increase; unix-ms is a safe default (aliases already
# do this). `--sequence` itself defaults to 1, which 409s on republish.

mj sites publish ./dist \
  --identikey-fp "$FP" \
  --site my-site \
  --keypair-file ~/.config/mjolnir/identikey.json \
  --sequence "$(date +%s)000"
```

What happens:

1. The CLI registers the IdentiKey pubkey with the host (idempotent).
2. It encrypts each file (public-mode: a per-snapshot seed, published in
   the manifest — integrity, not secrecy).
3. It POSTs the signed manifest. The server replies with which chunks it
   lacks.
4. It uploads only the missing chunks.
5. It POSTs a signed HEAD pointer. The host materializes a plaintext tree
   the gateway can `ServeDir`.

On success you see a snapshot hash, a sequence, and a **Serve URL** like:

```
https://api.vm.worldtree.network/api/sites/<fp>/my-site/files/
```

**That URL is not the public website.** It is the authenticated API debug
path. Hitting it from a browser without a JWT 401s. The public site is the
custom domain in the next section.

`--sequence` defaults to `1`. A second publish with the default is a 409
`sequence_regression`. Always pass a higher number. Unix milliseconds is
the least-thinking option; `--sequence 2`, `3`, … also works if you track
it.

`--site` is the name inside your IdentiKey (`blog`, `docs`, `www`). It is
not a domain. You can publish several sites under one key.

`--identikey-fp` must match the keypair. The CLI checks and refuses a
mismatch. There is no "just use the keypair, derive the fp" shortcut on
`mj sites publish` today.

### Mix / Justfile (only from this repo)

If you are sitting in a Mjolnir checkout and talking to a host over the
Justfile's SSH tunnel, the Mix wrappers exist:

```bash
mix mjolnir.publish ./dist --site my-site
# or
just sites-publish ./dist <fp> my-site <sequence>
```

`mix mjolnir.publish` is the friendly one: auto-creates
`~/.config/mjolnir/identikey.json`, defaults `--site` to the directory
basename, defaults `--base-url` to `http://localhost:<api_port>`. It still
defaults `--sequence` to `1`.

Those commands are **not** the path from another project. They need Mix,
the Mjolnir app, and usually an SSH tunnel so curl looks like localhost.
From the site's own directory, use `mj`.

---

## 3. Put it on a domain

A published snapshot is stored. It is not on the public web until a
**custom-domain alias** is bound and DNS + TLS reach the gateway.

```bash
mj domain set my-site blog.example.com \
  --keypair-file ~/.config/mjolnir/identikey.json
```

`<app>` is the **site name** when `--keypair-file` is present. The CLI
signs an alias record with your IdentiKey and PUTs it. Sequence for
aliases defaults to unix-ms, so you usually do not pass `--sequence`.

Then DNS:

| Record | Name | Value |
|---|---|---|
| `A` or `CNAME` | `blog.example.com` | the gateway that already terminates TLS for this host |

The name must **not** already be a declared gateway apex/route (those win).
Unknown Host headers fall through to the sites resolver: lookup the alias,
serve `<materialized>/<fp>/<site>/current/` from disk.

Point DNS at the same place your other Mjolnir-hosted names already go
(today: the WorldTree hypervisor's gateway). Do not CNAME onto
`*.vm.worldtree.network` and expect the wildcard cert to cover
`blog.example.com` — browsers want a SAN for the name they typed.

### TLS

`mj cert issue blog.example.com` is built for **deployed apps**, not
Sites. It 404s `app_not_found` unless a `Deploy.Registry` app owns that
fqdn. A Sites alias is not an app.

Until that is wired, TLS for a Sites domain is an operator step:

1. **HTTP-01 on the host** (the name must already hit the gateway on
   port 80):

   ```bash
   # on the host, as the mjolnir user — PEMs never leave the box
   /usr/local/bin/mjolnir-gateway cert issue \
     --domain blog.example.com \
     --email you@example.com \
     --out /var/lib/mjolnir-gateway/issued/blog-example-com \
     --http01-dir /var/lib/mjolnir-gateway/http-01
   ```

   Then install a `[[cert]]` in `/etc/mjolnir/gateway.toml` (or the
   gateway's cert-ensure path) and `systemctl reload mjolnir-gateway`.

2. **Cloudflare (or any reverse proxy) in front**, terminating TLS and
   forwarding HTTP. This is the documented Phase-1 option in
   [`identikey-sites.md`](../plans/initiatives/identikey-sites.md) §6.5.
   Exit = re-point the CNAME.

Without a cert for that exact name, the TLS handshake fails *before* the
sites resolver runs. The snapshot can be perfect and the browser still
shows a certificate error.

### Check it

```bash
curl -sS https://blog.example.com/ | head
# and a hashed asset, if the generator emits one:
curl -sSI https://blog.example.com/_app/immutable/some-file.js | grep -i cache-control
```

HTML is `max-age=0, must-revalidate` so a new publish is visible immediately.
SvelteKit's `/_app/immutable/` is `immutable` / one year.

---

## 4. Update the site

Rebuild, then publish again with a **higher** `--sequence`. Same site name,
same keypair. Chunks the host already has are skipped.

```bash
npm run build
mj sites publish ./dist \
  --identikey-fp "$FP" \
  --site my-site \
  --keypair-file ~/.config/mjolnir/identikey.json \
  --sequence "$(date +%s)000"
```

No gateway reload, no VM restart. HEAD flips; `current` is an atomic
symlink. Rollback is "publish an older tree" (or keep the previous
snapshot hash and re-HEAD it) — there is no `mj sites rollback` yet.

---

## 5. CI

Keep the boundary the rest of Mjolnir uses: **CI builds and publishes;
the host stores and serves.**

```yaml
- name: Build
  run: npm ci && npm run build

- name: Publish
  env:
    MJOLNIR_TOKEN: ${{ secrets.MJOLNIR_SITES_TOKEN }}
  run: |
    mj sites publish ./dist \
      --identikey-fp "$SITE_FP" \
      --site my-site \
      --keypair-file "${{ secrets.IDENTIKEY_JSON_PATH }}" \
      --sequence "$(date +%s)000"
```

The IdentiKey secret has to be in CI somehow (file on the runner, or a
secret written to a 0600 path at the start of the job). The JWT/`mjsk_`
token only authorizes the HTTP calls; the keypair is what the host
verifies on HEAD.

Do not use a full `mj login` token in CI if you can avoid it. Mint a
sites token bound to that fingerprint (and site).

---

## Limits and gotchas

| Thing | What happens |
|---|---|
| `--sequence` omitted on publish 2+ | 409 `sequence_regression`. Pass a higher number. |
| File > 64 MiB | Publish aborts for that file. |
| Client-side router, no prerender | 404 on every deep link. Prerender, or use `mj deploy`. |
| Serve URL printed after publish | Authenticated API path, not the public site. |
| `mj cert issue` on a Sites domain | 404 `app_not_found`. Operator TLS, or Cloudflare. |
| Keypair left at `./identikey.json` | Easy to commit. Always `--out ~/.config/mjolnir/identikey.json`. |
| `mix mjolnir.publish` from the site repo | Mix isn't there. Use `mj`. |
| Publishing `src/` instead of `dist/` | It will happily upload your TypeScript. Publish the build output. |
| Symlink in the output dir | Elixir publisher skips; Rust `mj` follows *file* symlinks. Don't. |

Inspect without the public domain (needs auth, or localhost on the host):

```bash
mj --help    # no sites-head subcommand yet
# authenticated GET, or from the host:
curl -sS "$MJOLNIR_API/api/sites/$FP/my-site/head"
curl -sS "$MJOLNIR_API/api/sites/$FP/my-site/files/index.html"
```

---

## Friction, and easier ways

The product principle on [`mjolnir-9bq.6`](../../docs/plans/initiatives/identikey-sites.md)
is: a newcomer types `mjolnir publish ./dist` and gets a public URL, signed
by their IdentiKey, with no other vocabulary. That Mix wrapper exists. The
command you can run *from another directory* is still the verbose
`mj sites publish` with four required ideas (fingerprint, site name,
keypair path, sequence).

Ranked by how much they hurt, and how cheap they are to fix:

### 1. Auto sequence (cheap, high leverage)

Aliases already default sequence to unix-ms. Publish defaults to `1`.
Every republish is a 409 unless you remember. **Default publish sequence
to unix-ms, or GET `/head` and send `current + 1`.** Then `--sequence`
is an expert override.

### 2. Friendly `mj` publish (the 9bq.6 surface, on the binary people have)

Port `mix mjolnir.publish` onto `mj`:

```bash
mj publish ./dist                 # identity at ~/.config/mjolnir/identikey.json
mj publish ./dist --name blog     # optional site name; default: dir basename
```

Derive the fingerprint from the keypair (do not ask for both). Create the
identity on first use. Print the **public** URL, not the API debug path.

`mj sites publish` can stay as the explicit/scripting form.

### 3. A URL that works without a custom domain (product hole)

Today a successful publish is stored-but-invisible unless you also bind a
domain, point DNS, and get a cert. Netlify/Pages give you
`something.netlify.app` immediately.

A host-owned default such as `https://<site>.<fp>.sites.worldtree.network`
(or a short name the operator already has a wildcard cert for) would make
step 2 produce something you can click. Custom domains stay for vanity.

This needs a gateway apex whose fallthrough does not steal the name for
Iroh, plus a cert that covers it. It is the missing half of "returns a URL."

### 4. `mj cert issue` for Sites aliases (medium)

`POST /api/certs/issue` looks up `Deploy.Registry` only. After `mj domain
set` for a site, the same command should see the alias in SecretStore and
issue HTTP-01. Until then, TLS is an operator or Cloudflare step — the
worst surprise in the flow, because everything else looked like it worked.

### 5. Don't ask for fingerprint and keypair

`--identikey-fp` is determined by the keypair. Requiring both is a chance
to mistype. `mj domain set --keypair-file` already derives the fp.

### 6. Site name default

`mix mjolnir.publish` defaults `--site` to the directory basename (`dist`
if you pass `./dist` — which is a bad default). Better: require `--name`
once, then remember it in `~/.config/mjolnir/sites/<name>.json` or a
`mjolnir.toml` in the project (`name = "blog"`, `dir = "dist"`).

### 7. Mix/Justfile as a trap

`just sites-publish` looks like the happy path if you find it first. It
runs Mix against localhost-via-SSH, defaults sequence to 1, and only
works from this checkout. The guide index should point at `mj`, not Mix.

---

## Target shape (what "easy" would be)

From the site's directory, after `mj login` once:

```bash
npm run build
mj publish ./dist --name blog
# → https://blog.<something-that-already-has-a-cert>
#    Signed by 9W3eTrPJoS4R2kXuB6Ny
#    Snapshot  <hash>

mj domain set blog blog.example.com     # keypair implied
# → CNAME blog.example.com to <gateway>
mj cert issue blog.example.com          # HTTP-01, because the alias exists
```

Republish is the same `mj publish ./dist --name blog`. Sequence is not a
user-facing idea.

That is the bar in 9bq.6. Everything in [§2](#2-publish-the-output-directory)
and [§3](#3-put-it-on-a-domain) is the workaround until that lands.

---

## Related

- [Deploying a Web App](deploying-an-app.md) — SSR / long-running process.
- [Getting Started](getting-started.md) — `mj` install and `mj login`.
- Design: [`docs/plans/initiatives/identikey-sites.md`](../plans/initiatives/identikey-sites.md)
- CLI: `mj sites --help`, `mj domain --help`, `mj cert --help`
- Operator: `mix mjolnir.sites.token`, `mix mjolnir.sites.materialize`
- ADR [0001](../decisions/0001-edge-strategy.md) — Sites as the static origin; CDN in front later if geo hurts.
