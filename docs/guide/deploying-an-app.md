# Deploying a Web App

How a web application becomes a live HTTPS URL on Mjolnir — the mental model, the moving
parts, and an honest account of what is shipped versus what still needs a human driving it.

> **TL;DR** — A deploy is an **immutable release snapshot**. Going live means booting a fresh
> microVM from that snapshot and cutting the gateway over to it. "Update the website" and
> "replace the VM" are the same sentence. Secrets never enter the snapshot.

If you think in Dockerfiles, read [Coming from Docker](coming-from-docker.md) first — this page
assumes that mapping and builds a deployment story on top of it.

---

## The superpower, stated plainly

Every other platform makes immutability *expensive*. On Docker, an immutable image costs you a
layer rebuild and a registry push; on Kubernetes it costs you a rollout. Because of that cost,
teams quietly drift toward mutating things in place — `rsync` the new build over the old one,
restart the process, hope.

On Mjolnir the economics invert. A snapshot is a `btrfs subvolume snapshot`: a metadata-only,
reference-counted clone that completes in about a millisecond **regardless of size** and shares
every unchanged block with its parent. Immutability is the *cheap* path.

That gives the deploy story three properties that are usually in tension:

1. **Every release is a real, bootable artifact.** Not a tarball you have to reconstitute — a
   machine you can spawn and poke at. Debugging "what shipped" means booting what shipped.
2. **Rollback is a metadata flip.** Re-spawn the previous release snapshot. No rebuild, no
   reverse-migration, no "rsync backwards and hope."
3. **Drift is structurally impossible.** Nothing mutates a running release. The only way to
   change production is to build a new snapshot, which means production is always exactly some
   named artifact you can identify and reproduce.

The cost of this on other platforms is what makes people avoid it. Here it's the *default*, and
fighting it is what costs extra.

---

## The model: a deploy is an immutable release snapshot

```
  source tree
      │
      │  build (layered, cached)
      ▼
  release snapshot          ← the immutable artifact. Named, spawnable, rollback-able.
      │
      │  spawn a fresh service VM
      ▼
  service VM  ──────────────► gateway route ──► https://your-domain
      │                         (regenerated on cutover)
      │  previous service VM is stopped
      ▼
```

Three rules follow from this, and they are the whole discipline:

- **Build produces a snapshot. Running consumes one.** The build never touches production; the
  runtime never builds.
- **Secrets are injected at spawn, never baked at build.** See [Secrets](#secrets-stay-out-of-the-snapshot).
- **Updates are cutover, not mutation.** There is no "just rsync this one file" fast path, and
  you should not add one — the layer cache already makes the honest path fast.

---

## Mapping the Dockerfile

The two-stage Dockerfile most web apps use maps almost 1:1 onto the deploy layer:

| Dockerfile | Mjolnir | Notes |
|---|---|---|
| `FROM node:23-alpine` | reflink clone of `@base/ubuntu-24.04` | runtimes installed via `mise` as a cached layer |
| `RUN bun install` | build step → snapshot layer | cache-keyed on the lockfile |
| `RUN bun run build` | build step → snapshot layer | cache-keyed on the source tree |
| multi-stage `COPY --from=build` | the final **release snapshot** | |
| `CMD node build/index.js` | generated systemd unit inside the guest | `Deploy.Runtime` installs it |
| `docker push` to a registry | *nothing* — naming the snapshot **is** the publish | no registry hop |
| `docker run` | `Deploy.Runtime.start` / `mj spawn --snapshot` | |
| `docker run -e SECRET=…` | managed secrets injected at spawn into tmpfs | never in the artifact |

### Two Docker habits to retire

**Retire the build-time `.env` dance.** A common Dockerfile trick is `cp .env.example .env`
before building so the framework's env loader doesn't complain. On Mjolnir this is unnecessary
and actively harmful: secrets are injected at *spawn*, so the build needs no env file, and
anything you write during the build is baked into the immutable artifact forever. Cut every
build layer *before* any secret exists.

**Retire image-size golf.** Alpine-minimalism exists because Docker images get pushed, pulled,
and stored per-tag. Mjolnir's base rootfs is a shared CoW subvolume — every VM reflinks it, so a
"large" Ubuntu base costs approximately zero marginal disk. Optimize for having the tools you
need, not for a number.

---

## The pieces

### `Deploy.Detector` — zero-config build plans

`lib/mjolnir/deploy/detector.ex` inspects an app directory and emits a `BuildPlan`.

**Current scope is deliberately narrow: SvelteKit with `adapter-node`.** Detection requires both
`package.json` and `svelte.config.js`; anything else returns `{:error, :unsupported_app}`.
Generalising to plain Node, Python, and Procfile apps is a follow-up.

The package manager is detected **from the lockfile, never assumed** — defaulting to npm breaks
bun and pnpm projects. Priority order is deterministic: `bun.lock`/`bun.lockb` → `pnpm-lock.yaml`
→ `yarn.lock` → `package-lock.json` → npm.

A detected plan looks like:

```elixir
%BuildPlan{
  runtime: "node@20",
  package_manager: :bun,
  steps: ["mise install", "bun install", "bun run build"],
  start_command: "node build/index.js",
  port: 3000
}
```

### `Deploy.Builder` — layered snapshots as a build cache

`Builder.build(base_layer_id, steps, opts)` runs the plan's steps in an ephemeral build VM,
snapshotting after each step and content-addressing the inputs (`Deploy.CacheKey`). A rebuild
where only the source changed reflink-clones the cached dependency layer and resumes from there
— the Docker layer cache, except each cache entry is a bootable machine. It returns a named
`release_snapshot`.

### `Deploy.Runtime` — boot, supervise, cut over

`Runtime.start(app_name, release_snapshot, plan, opts)`:

1. Spawns a **fresh** service VM from `release_snapshot`.
2. Waits for the guest to come up (Iroh ticket).
3. Generates and installs a systemd unit inside the guest with `PORT` set.
4. Writes the `Deploy.Registry` entry.
5. **Stops the previous service VM** — the cutover.

The generated unit runs `ExecStart=/bin/sh -lc '<start_command>'`. The login shell is
load-bearing: it is what sources `/run/mjolnir/secrets.env`. Do **not** "fix" this by adding
`EnvironmentFile=` — that file is shell syntax (`export KEY='value'`), which systemd cannot
parse.

### `Deploy.Registry` — the app → VM binding

One JSON file per app at `/var/lib/mjolnir/deploy/registry/<slug>.json`, mirrored in ETS, with
atomic write-then-rename. The entry carries `app_name`, `release_snapshot`, `service_vm_id`,
`url`, `custom_domain`, and `port`.

Registering `custom_domain` is what makes routing automatic — the gateway route generator derives
the backend from the binding instead of needing a hand-edited config.

### The gateway — routing and TLS

`Mjolnir.Gateway.Routes` renders `/etc/mjolnir/gateway.d/apps.toml` from live VM state plus the
registry; `RouteReconciler` regenerates it on VM-lifecycle and deploy events (debounced) and
reloads the gateway (`SIGHUP` → atomic `ArcSwap` of the route table). TLS is DNS-01 ACME, with
the certificate SAN list derived from the configured domains.

**This is why cutover must regenerate routes, not skip them:** guest IPs are derived
deterministically from the VM id (`SHA256(vm_id)` into `10.200.0.0/10`), so every redeploy —
being a new VM — lands on a new IP. Route regeneration is load-bearing, not cosmetic.

### Secrets stay out of the snapshot

Use `secrets_mode: :managed` (host-escrowed). `mj deploy` enrolls that mode **automatically**
when a secrets file exists for the app name.

**Path the orchestrator actually reads:**

```
/var/lib/mjolnir/deploy/secrets/<slug>.json
```

`<slug>` is the deploy name, lowercased, with every character outside `[a-z0-9_-]` replaced
by `_`. `mj deploy --name hypersigil-api` reads `hypersigil-api.json`. Omitting `--name`
uses the source directory's basename. `--name hypersigil` looks for `hypersigil.json` and
**misses** the Hypersigil tenant file.

Do **not** put secrets at `/var/lib/mjolnir/<app>-secrets.json`. That path is not read.

The file is a flat JSON object of string keys to string values (valid env names). The whole
map is injected — `DATABASE_URL`, `JWT_SECRET`, CORS, whatever is there. Missing or empty
file → deploy proceeds with no secrets (`secrets_mode: none`).

A declared host-sidecar tenant (`Tenants.ensure`, slug `hypersigil-api`) writes `DATABASE_URL`
into that same file and **merges**, so existing keys survive `ensure`. See
[`../runbooks/host-postgres-tenants.md`](../runbooks/host-postgres-tenants.md).

The rest of the shape:

- File is `0600`, *off* the BTRFS data volume.
- Injected at **`Runtime.start` only — never `Builder.build`.** Baking LUKS into the release
  snapshot keys it to a throwaway build VM and defeats the design. `mj deploy` already
  obeys this.
- The guest renders them to `/run/mjolnir/secrets.env` on **tmpfs**. Snapshots stay copyable.
- Rotation of a tenant password: `mix mjolnir.pg.tenant ensure <db> --slug <slug> --rotate`,
  then redeploy so the guest gets the new URL.

Trade-off, stated honestly: `:managed` is **not** zero-knowledge. The host can read the
credentials because the host injects them. It buys ciphertext-at-rest, an off-volume passphrase,
opaque snapshots, and transparent dormancy/wake — not survival of a host compromise. See
[`../secrets-architecture.md`](../secrets-architecture.md).

---

## Status: what actually works today

**Updated 2026-08-19.** The July write-up is stale on the CLI and the secrets path.

| Piece | Status |
|---|---|
| Base images (`ubuntu-24.04`, `ci-ubuntu-24.04`, `arch`) | ✅ present |
| BTRFS clone / snapshot / spawn-from-snapshot | ✅ shipped, exercised daily |
| `Deploy.Detector` / `BuildPlan` / `CacheKey` / `Builder` / `Runtime` / `Registry` | ✅ in the prod release |
| Gateway route generation + reconciler + DNS-01 TLS | ✅ shipped |
| `mj deploy` CLI | ✅ `mj deploy [PATH] --name <app>` → `POST /api/deploy` |
| Secrets file | ✅ `/var/lib/mjolnir/deploy/secrets/<slug>.json` auto-read on deploy |
| Host-sidecar tenant `hypersigil` | ✅ provisioned; `DATABASE_URL` is in `hypersigil-api.json` |
| Detector scope | SvelteKit + `adapter-node` only; anything else is `:unsupported_app` |
| Zine | still **hand-provisioned** (`secrets_mode: none`). Not an example to copy. |
| IdentiKey Sites | Recrypt path incomplete |

The first Hypersigil app deploy through this path is still the thing to do, not a
completed run. Expect to debug the first cutover.

---

## Deploying an app today

**1. Escrow secrets (once), if the app needs any.**

After the app exists in the deploy registry:

```bash
# Hidden prompt (preferred — value stays out of argv / history)
mj secrets set hypersigil-api STRIPE_API_KEY
printf '%s' "$STRIPE_WEBHOOK_SECRET" | mj secrets set hypersigil-api STRIPE_WEBHOOK_SECRET --stdin
mj secrets ls hypersigil-api
```

That merges into `/var/lib/mjolnir/deploy/secrets/<slug>.json`. It does not
replace the file, so `DATABASE_URL` / `REDIS_URL` from sidecar `ensure`
survive. Then **redeploy** the app so spawn injects the new env.

Keys must be valid env names (`[A-Za-z_][A-Za-z0-9_]*`); values are strings.
`mj secrets ls` prints names only.

For a host-sidecar tenant, skip setting `DATABASE_URL` by hand —
`mix mjolnir.pg.tenant ensure hypersigil --slug hypersigil-api` already wrote it.

**2. Deploy.** From the app tree, authenticated `mj` (`mj login`):

```bash
mj deploy --name hypersigil-api --domain shop.example
```

`--name` is required for the secrets file to match unless the directory *is*
already named `hypersigil-api`. `--domain` is optional (`X-Domain`). The CLI
tars the tree (honoring `.gitignore`), `POST`s `/api/deploy`, and prints the
URL. The server reads the secrets file, builds, boots with `secrets_mode:
:managed`, and cuts over.

**3. Verify — actually verify, don't assume.**

```bash
# the app process really sees the secret (blank means it started before injection)
mj exec <vm_id> 'printenv DATABASE_URL'
```

Then hit the URL and exercise a code path that uses the database end to end.

**4. Update = `mj deploy` again.** Dependency layers cache; typically only the
build step reruns. Cutover is automatic.

**5. Roll back** by calling `Runtime.start` with the *previous* `release_snapshot`.
No rebuild.

### Escape hatch (no CLI)

If `mj deploy` is the thing that is broken, the same pipeline is still
`Mjolnir.Deploy.Orchestrator.deploy/3` over `mjolnir rpc`. Read secrets from
`/var/lib/mjolnir/deploy/secrets/<slug>.json`, never the old
`/var/lib/mjolnir/<app>-secrets.json` path. Creds go to `Runtime.start`,
**not** `Builder.build`.

### If the builder gives you trouble

The fallback is the same artifact shape, driven by hand — spawn from a base image, `mj exec` the
build steps, `mj snapshot create` the result, then `Runtime.start` against that snapshot name.
You lose the layer cache, not the model, and it upgrades in place once `Builder` is proven.

---

## Sizing and scope

**One small VM.** A Node app serving mostly-prerendered pages plus a few API handlers idles
around 60–100 MB RSS; 512 MB is comfortable. With managed secrets enabling dormancy, a
low-traffic site can park at zero compute and wake on request.

**Don't split static from dynamic yet.** Publishing fingerprinted build assets to IdentiKey Sites
and keeping only the server-rendered routes on the VM is a sanctioned future direction
([ADR 0001](../decisions/0001-edge-strategy.md)), and framework asset fingerprinting makes that
migration mechanical when the time comes. But Sites is not finished, there is no measured
latency pain today, and a split means two artifacts that must version together. One artifact
until something actually hurts.

---

## Where CI fits

The Forgejo runner executes CI jobs *in Mjolnir microVMs* (`ubuntu-24.04` → `ci-ubuntu-24.04`).
The natural end state is push-to-deploy, but keep the boundary the deploy design draws:
**CI is the trigger and the quality gate; the deploy layer owns build, snapshot, and cutover.**

```yaml
- bun install && bun run check && bun test   # CI's job: gate
- mj deploy --name <app>                     # deploy layer's job: build → snapshot → cutover
```

A CI job that hand-rolls `btrfs` calls is a kludge one layer up. Note also that the only secret
CI ever needs is a Mjolnir API token — application secrets are host-escrowed and injected at
spawn, so they never enter CI at all.

Sequencing matters: get a manual deploy working first, then automate it. CI automating a working
deploy is an afternoon; CI *being* the deploy mechanism while it's unproven is a debugging swamp.

---

## See also

- [Coming from Docker](coming-from-docker.md) — the concept mapping and storage primitives.
- [Working with Snapshots](snapshots.md) — the primitive underneath all of this.
- [Gateway Routing](../gateway-routing.md) — how a hostname resolves to a VM.
- [Secrets Architecture](../secrets-architecture.md) — modes, threat model, LUKS details.
- [Host sidecars](host-sidecars.md) — overlay services every VM can reach (`10.200.0.1`)
- [Host sidecar tenants](../runbooks/host-postgres-tenants.md) — `Tenants.ensure` and
  `DATABASE_URL` for Hypersigil.
- [`plans/initiatives/mjolnir-deploy.md`](../plans/initiatives/mjolnir-deploy.md) — the design
  this implements and the roadmap beyond it.
