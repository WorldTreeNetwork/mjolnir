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

`hosted-*` snapshots pause the VM then strip `XAI_API_KEY` from grok
config, shell history, and the storefront `.env` on the rootfs before
the BTRFS snapshot. Tmpfs inject (`/run/mjolnir/`) is unchanged.

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

`Mjolnir.GitSigning.mint/1` (or `put/2`) stores the private key under
`_opaque/vms/<vm_id>/git_signing` (mode 0600). Boot injects
`/run/mjolnir/git_signing_key`. The private key is never on the VM
struct or `GET /api/vms`. Guest `user.signingkey` stays that path
across respawns so `git config` does not need a rewrite.

identikey-core `POST /devices/ssh_git` inserts `credentials.kind =
ssh_git` only after a fresh A3 WebAuthn assertion and a consent-log
`add_device` row. Elect-only is refused. The public key is
`device_public_key`; the private key never leaves Mjolnir.

The host registers that pubkey as a **write deploy key** on Forgejo
`VirtueInnova/hypersigil-store-frontend` (`POST /api/v1/repos/…/keys`,
`read_only: false`). Title includes `vm_id` (and `xid` if known). The
Forgejo key id is stored on device meta (`forgejo_key_id`), never the
private key. Token is host-only: `MJOLNIR_FORGEJO_TOKEN` (runtime.exs),
`Authorization: token …`. Do not log it. Do not put it on the guest or
the snapshot. Guest `git` uses `IdentityFile=/run/mjolnir/git_signing_key`
and baked `known_hosts` for `mimir.worldtree.network`.

API URL is `forgejo_url` or `runner_forgejo_url` (`http://127.0.0.1:3000`
on mimir). Prod hosted-being provision **requires** the token.

Respawn is a new device (`GitSigning.respawn/2`): new `vm_id`, new
keypair, never copy `_opaque` across ids. Revoke order for the old
device:

1. Forgejo write-key delete (`DELETE /api/v1/repos/…/keys/:id`, or
   match by pubkey). A failed delete is an error — opaque stays.
   No token is `:not_wired` (dev/test reconcile find only).
2. identikey `POST /devices/ssh_git/revoke` (`revoke_device` /
   `revoke_ssh_git`)
3. Opaque delete

If step 1 or 2 fails, the private blob stays so a crash cannot leave a
live key with no identikey row. Respawn mints the new key (registers a
new Forgejo write key) then revokes the old one.

Remote URL (bootstrap default; Forgejo advertises `ssh://git@mimir…`):

```
forgejogit@mimir.worldtree.network:VirtueInnova/hypersigil-store-frontend.git
```

Host SSH user is `git` (no `forgejogit` passwd). Bootstrap sets
`url.git@mimir.worldtree.network:.insteadOf forgejogit@…` and
`Host mimir.worldtree.network` `User git` so that spec URL still
clones. GitHub origin is not required. Spawn with `git_signing: true`
so mint registers the deploy key **before** bootstrap clones.

CLI `mj spawn` on the current `mj` 0.1.0 binary does not list
`--preserve-iroh-key`; `POST /api/vms` with `preserve_iroh_key: true`
is the confirmed working form. Do not reimplement the flag.
