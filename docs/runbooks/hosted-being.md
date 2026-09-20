# Hosted being (vibe-coder VM)

ADR 0011. Friend's C2 identikey; the VM is a device. Preview talks to
prod `https://api.hypersigil.world`.

## Login

Set on the host:

```
MJOLNIR_AUTH_ISSUER=https://auth.identikey.me
MJOLNIR_AUTH_CLIENT_ID=mjolnir-term
MJOLNIR_AUTH_REDIRECT_URI=https://api.vm.worldtree.network/auth/callback
```

Live OP (2026-09-20): public PKCE client `mjolnir-term` is registered
on `auth.identikey.me` via `IDENTIKEY_CLIENTS` (append, never
replace). `auth: none`, `subject_type: public`, redirect
`https://api.vm.worldtree.network/auth/callback`. Existing clients
kept: `IDENTIKEY_CLIENT_ID=taskmaster`, extra
`taskmaster-laptop` + `wtnf-web`. Passkey at `/authorize` opens
`/term/:id`. grok uses `XAI_API_KEY` in `/run/mjolnir/` tmpfs, not
OIDC.

```json
{"id":"mjolnir-term","auth":"none","subject_type":"public","redirect":"https://api.vm.worldtree.network/auth/callback"}
```

Guest `identikey` (`1769d148-8949-457b-806f-1e467046da94`). After
`mj secrets set identikey IDENTIKEY_CLIENTS --stdin`, restart
`identikey.service` on that VM — do not `mj deploy` from a laptop
(still defaults to `deploy-node-bun`). Unknown passkey assertion
returns `credential not found` and does not insert an account.

Existing Keycloak `owner_id`s on mimir will not match an XID `sub`.

## Bootstrap

Spawn `ubuntu-24.04` (2048 MB or more — bun/Vite). No new `@base/`
name.

```
mj spawn --base ubuntu-24.04 --memory 2048
# copy scripts/hosted-being-bootstrap.sh in via exec, then:
#   bash /tmp/hosted-being-bootstrap.sh
curl -fsSL https://raw.githubusercontent.com/identikey/mjolnir/main/scripts/hosted-being-bootstrap.sh | bash
```

Bootstrap installs bun, grok CLI, clones
`hypersigil-store-frontend`, and starts `bun run dev --host --port 80`
in tmux `session=main` window `vite` so the process survives `mj exec`.
PATH includes `$HOME/.bun/bin`. Vite 6+ host check is opened with
`__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=.vm.worldtree.network` so the
ticket Host is not 403. `mj connect --session main` is the shell pane.

`mj url` is `https://<ticket>.vm.worldtree.network` (gateway default
guest port 80). That origin is the preview. CORS for it is
`update-hypersigil-store-cors` (not this landing). If HMR websocket
fails through Iroh, first paint is still the gate.

Do **not** write `XAI_API_KEY` onto the guest disk or the snapshot
tree. Inject it into `/run/mjolnir/` tmpfs after boot (and again
after every respawn). Bootstrap refuses a `.env` that contains the
key.

## Per-friend snapshot

After bootstrap, snapshot as `hosted-<xid>` under `@snapshots/`
(throwaway confirm without a friend XID: `hosted-devpreview-test`).
This is not a catalog `@base/` name.

```
mj snapshot create <id> hosted-<xid>
```

Respawn from **that** snapshot with `preserve_iroh_key: true` so the
ticket URL (and later CORS) survive. The flag already exists on
`VM.spawn` and `POST /api/vms` — do not reimplement it.

```
# CLI (same flag as docs/security/iroh-connectivity-guide.md)
mj spawn --snapshot hosted-<xid> --memory 2048 --preserve-iroh-key

# API
POST /api/vms
{"snapshot":"hosted-<xid>","memory_mb":2048,"preserve_iroh_key":true}
```

A **shared** bootstrap snapshot (grok+bun+git for cloning, not a
friend) MUST NOT preserve Iroh identity. Omit the flag; default is
`false`. Two VMs must not share a node id.

Respawn is a new device (new `vm_id`, new SSH key). Vite is a
process — re-run the bootstrap (idempotent) or start
`bun run dev --host --port 80` in tmux `main` again after boot.
Re-inject `XAI_API_KEY` into tmpfs; it is not in the snapshot.

## Git key

`Mjolnir.GitSigning.put/2` then boot injects
`/run/mjolnir/git_signing_key`. Forgejo write registration is
`add-honor-git-remote`. Until that lands, `git clone` of
`forgejogit@mimir.worldtree.network:VirtueInnova/hypersigil-store-frontend.git`
from a fresh `ubuntu-24.04` fails (`Permission denied (publickey)`).
Seed `WORKDIR` via `scp` + `mj proxy` (not extra_mounts) so
`.git` exists and bootstrap skips clone.

CLI `mj spawn` on the current `mj` 0.1.0 binary does not list
`--preserve-iroh-key`; `POST /api/vms` with `preserve_iroh_key: true`
is the confirmed working form. Do not reimplement the flag.
