# Mjolnir Deploy — the "git push and it's live" layer

**Status**: Design (2026-06-22)
**Owner**: Duke
**Builds on**: `host-reconcile.md` (Forge), `identikey-sites.md` (Sites), the snapshot/dormancy machinery in `Mjolnir.VM`.
**CLI surface**: `mj deploy` (and friends) — extends the existing Rust client, authenticated to a server like any other `mj` command.

---

## The one-sentence pitch

`mj deploy` in an app directory should, with **zero configuration for the common case**, build the app inside a microVM, snapshot every build step so rebuilds are instant, boot the result as a supervised service, and hand back a live HTTPS URL — recapturing the Heroku "wow" that the current PaaS landscape has buried under YAML.

## Why now / why us

Every modern platform (Vercel, Fly, Render, Railway, raw k8s) has drifted toward "configure first, deploy later." The thing that made Heroku magic — `git push heroku main` and it *just knew* — is gone. Mjolnir has two primitives nobody else has stacked together:

1. **Instant CoW snapshots** (BTRFS reflink) — a near-free, content-addressable layer cache, but for *full microVMs* instead of overlayfs containers.
2. **A clean control plane + gateway** — spawn, exec, snapshot, and a public HTTPS URL per VM, already authenticated and working.

The deploy layer is the thin thing that turns those primitives into a product moment.

## Goals

1. **Zero-config common path.** `mj deploy` in a SvelteKit (or Node, or Python…) repo Just Works. No manifest required to get to a live URL.
2. **Instant rebuilds.** Re-deploying after a one-line change reuses every unchanged build step via snapshot layers. Sub-second cache hits.
3. **No user shell scripts.** The escape hatch for customization is a small declarative manifest, never a `deploy.sh`.
4. **Reproducible and inspectable.** A deploy is a chain of content-addressed snapshots; you can boot any layer to debug it.
5. **Plays to the existing stack.** Reuse `Mjolnir.VM` (spawn/exec/snapshot), the gateway (HTTPS URL), `mise` (runtime install), and Forge *resources* (run-state config). Build as little new as possible.

## Non-goals (for now)

- **Not a build farm / multi-arch / remote cache.** Single host, single arch (x86_64) to start — same scope discipline as the rest of Mjolnir today.
- **Not zero-downtime rolling deploys.** v0 is stop-old/start-new with a brief blip. Blue/green is a later layer once the core moment lands.
- **Not a general CI system.** That's the Forgejo runner's job. Deploy *consumes* a build; it isn't a pipeline engine.
- **Not Sites.** Static assets ride inside the app's own server (adapter-node serves them; CDN caches them). Sites stays the signed-publishing system, untouched. See "Relationship to Sites" below.
- **Not a new general-purpose DSL.** Detection first; the manifest is a thin override surface, not a programming language.

---

## The core insight: a deploy is two phases with different shapes

This is the load-bearing design decision, and it's why the deploy layer is **not** "Forge with an `exec` resource bolted on."

| Phase | Shape | Right tool |
|---|---|---|
| **Build** — `mise install node@20`, `npm ci`, `npm run build` | Imperative, **ordered**, side-effecting, *not* idempotently observable. "Did `npm run build` run?" has no canonical answer. | **Snapshot-layer builder** (new, small) — each step → BTRFS snapshot, content-addressed for cache reuse. Dockerfile semantics on real VMs. |
| **Run-state** — the app's systemd unit, env file, service user, listen port | Declarative, **convergent**, canonically observable. | **Forge resources** (`systemd_unit`, `file`, `user`) reconciled *inside the guest*. Reuses existing code; gives drift detection for free. |

### Why not make Forge the chassis

Forge's core invariant is that **every resource is observable and idempotent** (`canonical/1`, `observe_path/1`, `parse_observed/1`, `apply/3`). A build step violates all three. Adding a generic `exec`/`command` resource to carry build steps would break the invariant that *is* Forge — at which point it's a worse Ansible. So:

> **Forge is a component of deploy, not its frame.** The snapshot builder is the frame. Forge reconciles the final run-state, driven over the guest agent's vsock `exec` transport (a cleaner transport than the currently-stubbed SSH one).

---

## Architecture

```
mj deploy  (Rust client, authed)
   │  POST /api/deploy   { app_tarball | git_ref, overrides }
   ▼
Mjolnir.Deploy.Supervisor                         ← NEW, under Mjolnir.Supervisor
├── Deploy.Detector      — buildpack: inspect files → build plan (runtime, steps, start cmd, port)
├── Deploy.Builder       — runs the ordered build plan; snapshots + content-addresses each layer
│      └── uses Mjolnir.VM.exec + Mjolnir.VM.snapshot + Mjolnir.BTRFS (reflink layer cache)
├── Deploy.Runtime       — boots the final snapshot as a service VM
│      └── reconciles run-state via Mjolnir.Forge (systemd_unit/file/user) over vsock
└── Deploy.Registry      — { app_name → current snapshot + service vm_id + url }, persisted
```

### Build = layered snapshots (the differentiator)

```
base: @base/ubuntu-24.04
  └─ layer L1  key=H(base, "mise install node@20")          → @snapshots/deploy/L1
       └─ layer L2  key=H(L1, "npm ci", lockfile-hash)      → @snapshots/deploy/L2
            └─ layer L3  key=H(L2, "npm run build", src-hash)→ @snapshots/deploy/L3  ← release
```

- Each step's cache key = `hash(parent_layer_id + step_command + relevant_input_hash)`.
  `npm ci` keys on `package-lock.json`; `npm run build` keys on the source tree hash.
- A cache **hit** is a reflink clone of the existing snapshot + skip to the next step — instant.
- A cache **miss** boots from the parent layer, runs the step via `VM.exec`, snapshots the result.
- Cold rebuild after a one-line `src/` change: L1, L2 hit; only L3 reruns. This is the "wow."

### Run = boot the release snapshot under systemd

- `VM.spawn(%{snapshot: release_layer})` → the app's files are already baked in.
- Forge reconciles the run-state inside the guest: a `systemd_unit` for the app
  (`Environment=HOST=0.0.0.0 PORT=…`, `Restart=on-failure`), an env `file`, a service `user`.
- The gateway already exposes it: `https://<z32>-<port>.vm.worldtree.network`.
- Bonus: because run-state is Forge-managed, drift ("someone SSH'd in and edited the unit")
  is detectable and re-convergeable — a property a shell-script deploy can never offer.

---

## The zero-config moment (buildpack detection)

The Heroku magic was never the config language — it was **not needing one**. `Deploy.Detector` inspects the app and produces a build plan:

| Detect | Plan |
|---|---|
| `package.json` + `svelte.config.js` (adapter-node) | PM **from lockfile** (`bun.lock`→bun, `pnpm-lock.yaml`→pnpm, `package-lock.json`→npm; default npm); runtime via mise; install prod deps · `<pm> run build` · start `<node\|bun> build/index.js` · port 3000 |
| `package.json` (generic Node) | PM/runtime from lockfile · install · `<pm> run build` if present · start from `scripts.start` |
| `requirements.txt` / `pyproject.toml` | mise: python · install deps · start from Procfile/`__main__` |
| `Procfile` present | honor it (Heroku-compatible process types) |

**Detect the package manager from the lockfile, not an assumption.** `npm`/`bun`/`pnpm`/`yarn` differ in install command, prod-dep flag, and — critically — lifecycle-script behavior (see hazards below). Defaulting to `npm ci` breaks bun/pnpm projects (field-validated against a bun + `bun.lock` SvelteKit app, 2026-06-23).

`mise` is the universal runtime lever — it's already in the base rootfs, and "install any language at a pinned version" is one `mise install` away (node *and* bun are mise-managed). By design no runtime is pre-baked; the deploy layer installs it as L1 and snapshots it, so the cost is paid once and cached forever.

Target experience:

```
$ mj deploy
→ detected: SvelteKit (adapter-node), Node 20 via mise
→ build  [cache hit: mise, npm ci]  ·  npm run build  ✓  (layer 3a9f…)
→ booted service VM · systemd unit `app` · :3000
→ live: https://app-7x2.vm.worldtree.network   (2.1s, 2/3 layers cached)
```

### Real-world build hazards (field-validated against Zine, a bun + adapter-node + better-sqlite3 app)

Detection getting the *commands* right isn't enough — real apps fail in the build/first-run, in ways the buildpack must anticipate:

1. **Native modules + bun's blocked postinstall.** bun suppresses dependency lifecycle scripts by default (supply-chain safety), so native addons like `better-sqlite3` never build/download their `.node` binary → a "Could not locate the bindings file" crash *at first DB access*, not at install. The buildpack must **detect native deps and trust their install scripts** (`trustedDependencies` / `bun pm trust`), or fall back to node (npm runs postinstall by default). General rule: **native deps must be installed/built on the target (linux-x64), with lifecycle scripts allowed** — never shipped from the dev Mac.
2. **Runtime ≠ package manager.** A bun project may still need to *run* under node if a native module has ABI friction under bun. "build-with-bun, run-with-node" is a valid split the detector should be able to choose.
3. **Prerender treats broken links as fatal.** SvelteKit's prerender aborts the build on a missing linked asset (e.g. a generated `/psd/.../x.png` that an app build-step produces). This is app config (`handleHttpError`), not a deploy bug — but the buildpack should **surface it clearly as an app build failure**, not a platform error, and the docs/output should point at the app's own prerender config.
4. **Apps have pre-build generators.** Real projects generate assets before `build` (Zine exports PSD layers via its own scripts). The buildpack can't know these; this is exactly what the optional manifest's custom `steps` are for.

The throughline: the zero-config path nails the *common* case, but the manifest escape hatch (custom build steps, runtime override, native-dep trust list) is **load-bearing for real apps** — design it in from P1, not as an afterthought.

### The optional manifest (escape hatch only)

When detection isn't enough, a small `mjolnir.toml` overrides — never replaces — the plan:

```toml
[app]
name = "my-api"
[build]
runtime = "node@22"          # override the detected version
steps   = ["npm ci", "npm run build:prod"]   # override build steps
[run]
start = "node build/index.js"
port  = 3000
env   = { PUBLIC_API = "https://api.example.com" }
```

No file = full detection. File present = detection + these overrides. Crucially, this is *declarative override*, not an imperative script.

---

## CLI surface (sketch)

```
mj deploy                 # build (cached) + release current dir; prints URL
mj deploy --name my-api   # name it (else inferred from dir / package.json)
mj deploys                # list deployed apps + URLs + current layer
mj deploy logs <name>     # tail the service (journald in the guest, via exec/syslog)
mj deploy rollback <name> # re-point to the previous release snapshot (instant)
mj deploy destroy <name>  # stop the service VM, keep/prune layers
```

Rollback is *free* because every release is an immutable snapshot — "re-point to previous layer" is a metadata flip + reboot, not a rebuild.

---

## Relationship to existing subsystems

- **Forge** — reused for run-state reconciliation, driven over vsock. Not the chassis. The host-self-config use case (`host-reconcile.md`) is unchanged; this is a *second consumer* of the same resource library, against guest targets.
- **Sites** — orthogonal. Sites is signed, verifiable, identity-bound publishing. Deploy serves static assets the boring correct way (the app's own server + CDN edge cache). Don't conflate them; don't route deploy through Sites.
- **Forgejo runner** — also orthogonal. The runner is CI (run a workflow in a VM). Deploy is "make my app live." They may share the layer-cache builder one day, but ship deploy standalone first.
- **Gateway** — reused as-is for the HTTPS URL. Note: the gateway is pass-through (no response cache), so static-asset caching is a CDN-in-front concern, not deploy's.
- **Secrets injector** — *reused as-is* for runtime env. It already exists: a LUKS2-encrypted volume in the guest (`native/mjolnir_guest_agent/src/secrets.rs`), fed over a default-deny Iroh ALPN (`SECRET_INJECT_ALPN`) from host-authorized peers (`VM.authorize_inject_peer/2`). This is the right home for app secrets — **do not** invent a Forge `file` for them. (Distinct from `Mjolnir.SecretStore`, which stores signed Sites envelopes — unrelated.) See "Secrets" below for the render-target fix and the recrypt end-state.
- **Recrypt** (`~/work/IdentiKey/recrypt`) — the **end-state** secrets transport. A proxy-recryption system (lattice PRE via OpenFHE + classical EC, KEM-DEM, Gordian Envelope, multi-sig auth) that transforms ciphertext-for-Alice into ciphertext-for-Bob without decrypting. Mjolnir's original purpose was to *host* recryption proxies; the deploy secrets story is a first consumer. Engine is substantially built and under active hardening; the greenfield work is the Mjolnir integration — hosting a proxy, mapping a keyspace to the **VM's own keypair**, and a guest-side `recrypt-client` (currently a stub). Near-term we bridge with re-inject (below).

---

## Source ingest (decided): tar the working dir first

The entry point is **tar the current directory**, not git. This is the Heroku moment — fewest things between intent and a URL, no auth dance, works on any folder including uncommitted changes.

- **P0 — tar cwd.** `mj deploy` packages the directory and uploads. Respect `.gitignore`/`.dockerignore`; when it's a clean git repo, prefer `git archive HEAD` (clean, gitignore-honoring), with `--dirty` to include uncommitted work. Covers private code with **zero credentials**.
- **P1 — public repo URL.** `mj deploy github.com/user/repo`, no auth. Covers "deploy this OSS thing."
- **P1 — private repo pull via deploy key (first-class).** Revised from an earlier "deferred/PITA" stance: in practice `ssh-keygen` + pasting a read-only **deploy key** into the repo host is *easy* (validated 2026-06-23 against Forgejo). So support `mj deploy <git-ssh-url>` where the VM clones over SSH with a generated deploy key. The flow: `mj` generates an ed25519 keypair per app, shows the user the public key to paste (or auto-registers it — see Forgejo note), stores the private key via the **secrets injector** (never on the rootfs/layers), and the guest clones with it. Revocation = delete the deploy key on the host.
  - **Forgejo synergy:** Mjolnir already runs its own Forgejo (the CI runner). For repos hosted there, deploy-key registration can be **fully automated** via the Forgejo API — no copy-paste at all. That's the closest thing to the "git push and it's live" moment for self-hosted repos, and it's uniquely cheap *because we own the forge*.
- **Later — PAT/token fallback.** For hosts without easy deploy keys, inject a PAT via the secrets injector and clone. Lowest priority; deploy keys cover the common case.

Rationale: tar-the-cwd stays the **front door** (zero auth, ship what's in front of you). But "configure a git credential" turned out to be a one-time `ssh-keygen` + paste, not a real barrier — so git-pull is a strong, first-class *second* option, not a someday-maybe. Owning the Forgejo instance makes the private-repo path especially turnkey.

---

## Storage, GC & billing

The intended economics: layers are owned by a user who pays for **passive storage** (layers retained) + **compute time** (VM runtime). Two engineering points make or break the fairness of that model.

### Meter exclusive bytes via BTRFS qgroups, not `du`

Reflink layers share blocks with their parents, so naive per-snapshot sizing double-counts shared data and overcharges everyone. Use BTRFS **quota groups (qgroups)** — assign each user (and/or layer) to a qgroup so BTRFS tracks *exclusive* vs *shared* bytes, and **bill the exclusive bytes** (the true marginal cost of retention). Same distinction as `docker system df`'s shared-vs-unique. Bake `owner_id` + qgroup attribution into the layer schema from day one; retrofitting it onto already-shared snapshots is painful.

### Two GC classes (aligns incentives)

| Class | What | GC policy | Billing |
|---|---|---|---|
| **Cache layer** | intermediate build step (`mise install`, `npm ci`, `build`) | LRU-evict freely under pressure — eviction only slows a future rebuild | light or none |
| **Release layer** | a deployed / rollback-able version | never auto-deleted; user prunes (`mj deploy prune --keep N`) | yes |

Deleting a release frees only its *exclusive* blocks (CoW), so cleanup cost equals exactly what was being billed — "keep what you pay for" is the natural, self-balancing incentive.

### Secrets ⇄ scale-to-zero coupling

Billing-for-compute wants **scale-to-zero**: idle apps go dormant, wake on request. But `secrets_mode: :persistent` VMs currently **refuse dormancy** (`vm.ex:657`) because nobody can supply the LUKS passphrase on auto-wake. So a secret-bearing app cannot scale to zero today.

- **Near-term (decided): automated re-inject on wake.** The control plane re-authorizes the peer and re-pushes secrets over the existing `SECRET_INJECT_ALPN` path when a VM wakes. Preserves the injector's zero-host-trust posture (passphrase/source stays external); the only new code is wiring re-inject into the wake path. This is what we build now.
- **End-state: recrypt-to-VM-key.** Secrets live encrypted-to-the-owner in a keyspace; a Mjolnir-hosted recryption proxy recrypts the bundle **to the VM's own keypair** on wake; the guest decrypts in RAM with a key only it holds. The host/proxy never see plaintext, revocation = drop the re-encryption key, and — crucially — **the persistent LUKS volume can go away entirely**, which *removes* the dormancy refusal at its root (no passphrase to reopen). Same mechanism delivers zero-host-trust *and* scale-to-zero. Depends on the recrypt integration (proxy hosting + guest `recrypt-client`).

### Keep plaintext off the rootfs (and out of layers)

The rendered env must stay off the rootfs — snapshotting the rootfs would otherwise bake secrets into the layer. Fixes, in order of effort:

1. ~~**Render to tmpfs.**~~ **Shipped.** The render target is **`/run/mjolnir/secrets.env`** (`SECRETS_ENV_PATH` in `secrets.rs`). `/run` is RAM-backed (tmpfs) on any systemd guest, so it is never persisted and never captured by a BTRFS snapshot. A service unit can consume it via `EnvironmentFile=/run/mjolnir/secrets.env`. (The LUKS *source* `.env` stays encrypted-at-rest; only the RAM copy is plaintext.)
2. **Better — in-memory via unix socket.** The guest agent holds injected secrets in memory and exposes them over a unix socket (or injects them directly into the service process environment at launch). Nothing — cipher or plain — touches disk.
3. **End-state — recrypt.** Secrets are recrypted to the VM key and decrypted in RAM per boot; no persistent secrets volume at all.

Avoid "render into the LUKS fs": the LUKS file lives on the rootfs, so a snapshot still carries the (encrypted) secret into the layer. tmpfs/socket carry nothing.

**Hard rule regardless:** cut build-cache layers *before* any secret load. Build-time secrets (e.g. a private-registry token) live outside the layer cache key *and* outside the snapshotted rootfs (inject to tmpfs for the build step, discard before snapshot).

---

## Open questions / decisions to make

1. ~~**Source ingest.**~~ **Decided** → tar the cwd first; see "Source ingest" above.
2. ~~**Layer GC.**~~ **Decided** → qgroup-metered, two GC classes; see "Storage, GC & billing" above. (Open: concrete retention defaults + when GC triggers.)
3. **Build isolation.** Build in an ephemeral VM, snapshot, discard the VM — or build in the eventual service VM? Ephemeral-build-then-promote is cleaner and matches the layer model.
4. ~~**Secrets ⇄ scale-to-zero.**~~ **Decided** → re-inject on wake now; recrypt-to-VM-key as end-state. Render to tmpfs (`/run`) immediately to keep plaintext off the rootfs. See "Secrets" above. (Open: the recrypt integration design — proxy hosting + guest `recrypt-client` — is its own initiative.)
5. **Forge-over-vsock transport.** Concrete shape of running resource `apply/3` against a guest via the agent's `exec`. De-risk with a spike before committing (this was the "validate Forge-over-vsock" option).
6. **Health gating.** Before flipping the URL to a new release, probe `GET /` (or a configured healthcheck) in the new VM? Needed for safe rollback-on-failure even in v0.
7. **Multi-process apps (Procfile `web` + `worker`).** One VM with multiple systemd units, or one VM per process type? Start single-VM, multiple units.

## Phasing

- **P0 — Prove the wow.** Hardcode the SvelteKit/adapter-node path. Builder with snapshot layers + cache. `mj deploy` → URL. No manifest, no rollback. Goal: feel the instant rebuild.
- **P1 — Generalize detection.** Buildpacks for generic Node / Python / Procfile. Optional `mjolnir.toml`. `mj deploys`, `logs`, `rollback`, `destroy`.
- **P1.5 — Secrets hygiene.** Render to tmpfs (`/run`) so no plaintext hits the rootfs; wire secret **re-inject on wake** so secret-bearing apps can scale to zero. Cheap, unblocks compute billing.
- **P2 — Run-state via Forge-over-vsock.** Replace ad-hoc systemd-unit-by-exec with real Forge reconciliation + drift detection.
- **P3 — Operability.** Layer GC/prune (qgroup metering), health-gated releases, multi-process.
- **Parallel track — Recrypt integration.** Host a recryption proxy on Mjolnir, map a keyspace to the VM keypair, build the guest `recrypt-client`. Replaces re-inject as the secrets transport and retires the persistent LUKS volume. Own initiative; not gated on the phases above.

## Risks / honest caveats

- **The builder is new code.** Small and sits on existing primitives, but the cache-key correctness (what invalidates a layer) is the kind of thing that's subtly wrong until battle-tested. Get keys right early.
- **mise/npm egress depends on host NAT** being bootstrapped (it is, today). Document it as a prerequisite.
- **Snapshot sprawl** is real; without GC from P1-ish, disk fills. Don't ship P1 without prune.
- **Scope gravity.** The temptation will be to grow this into "a PaaS." The discipline that makes it *good* is the zero-config moment, not the feature count. Resist YAML.
```
