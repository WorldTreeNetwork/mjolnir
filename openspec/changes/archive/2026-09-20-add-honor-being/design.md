# Design — Hosted being (vibe-coder VM)

Canonical ADR index:
[`docs/decisions/0011-honor-being.md`](../../../docs/decisions/0011-honor-being.md).
This file is the full argument.

**Status:** Accepted (Fable re-advise 2026-09-10). ACTIVE BUILD.
Renamed 2026-09-10: product is a **hosted being** (intend
mis-transcription “Honor”). Change-id unchanged.
**Change:** `add-honor-being`
**Epic bead:** `mjolnir-x97p`
**Architecture bead:** `mjolnir-x97p.1`
**First consumer:** VirtueInnova `hypersigil-store-frontend` (user
said hypersigil-frontend).

Grok authored. Advise reader must not be Grok (ADR-005). Fable 5.1
is the cross-family reader. Send-back 2026-09-10
(`reviews/2026-09-10-advise.md`) amended Decisions 1–3, 5–7
(S1–S4). Re-advise after this amend.

## Problem

Five questions after intend + steer:

1. Whose identikey is the machine bound to?
2. How does grok “log in” relative to IdentiKey passkey-on-web?
3. What private key does the VM hold so git commits are signed and
   attributable?
4. Which git host is the write remote (CI/CD)?
5. How is the Vite preview reached?

## Decision 1 — Friend C2; the VM is a device of that XID

The vibe-coder friend receives a **C2 managed** identikey
(`identikey-core` `managed-custody`). The hosted being is not a second
inception identity. It is a **device** of that XID: a
`credentials` row (same table as passkeys, `add-device-records`),
not an `add_key` of Sign onto the document.

**Mjolnir binding (S3):** the VM's `owner_id` is the friend's XID
as `auth.identikey.me` issues it in OIDC `sub`. `/term` and the
PTY attach are authorized by `authorize_vm` on that equality. A
VM Duke spawns under his own `sub` is not this hosted being. Pairwise
`sub` is not used for this client (`subject_type=public` so `sub`
is the 64-hex XID).

Duke may hold Elect recovery material for that C2 identity so the
friend cannot be stranded. Duke is not the Sign subject of the
being.

Rejected:

- Duke-owned being with the friend as a guest (faster; fails the
  exit test for the friend — they cannot leave with the identity)
- A throwaway C0 per VM (no recovery, no git attribution)

## Decision 2 — Passkey gates /term; grok is an xAI API-key client

`https://auth.identikey.me` already serves discovery and the
passkey HTML at `/authorize` (folded `add-hosted-login-ui`,
`5gh.1`). wrug.3 opened `/term` via Keycloak device-flow on
`connect.identikey.io`. That stand-in is done; the being's
browser login is **this** OP, passkey only.

**Scope of the gate:** passkey opens wrug `/term` (ADR 0004:
foreign-origin page never holds the Mjolnir JWT). The Vite
preview on the ticket host is **unauthenticated** through the
gateway. "Passkey gates the being" is true of `/term`, not of
`mj url`.

Grok in the guest still needs xAI inference. IdentiKey OIDC does
not mint grok.com tokens. `GROK_OIDC_ISSUER=https://auth.identikey.me`
without `GROK_CLI_CHAT_PROXY_BASE_URL` is a dead end. v1 stores
**`XAI_API_KEY` only** (no grok.com session — that is a personal
account credential whose owner and lifecycle this system does
not hold). Inject into `/run/mjolnir/` tmpfs via the same vsock
path as `buzz.env`, so a bootstrap snapshot never captures it.

The human never “logs into grok” with a passkey; they log into
the **hosted being**, then grok runs.

Rejected:

- Grok OIDC against identikey as the session (loopback
  `http://127.0.0.1/callback` on a remote VM; no xAI proxy)
- Growing Keycloak/`connect.identikey.io` surface
- Device-code grant on identikey-oidc as a v1 requirement
- grok.com device-auth / session cookie as the inference
  credential

## Decision 3 — `ssh_git` credential, A3 consent, vsock-injected SSH key

Git commit signing is SSH (`gpg.format ssh`). The private key
lives in SecretStore `_opaque/vms/<id>/` (buzz nsec pattern,
`mjolnir-1pe`). Inject over vsock on every boot into guest
tmpfs. Never on the VM struct, StateStore, or API views.

**Kind (S2):** a new `credentials.kind = 'ssh_git'` with
`device_public_key` populated. Today's CHECK is
`passkey | oidc_apple | oidc_google | identikey_auth`. Do not
overload `identikey_auth` (that kind authenticates *to* the OP).
The migration lives in identikey-core and is owed by
`add-vm-git-subkey`.

**Consent (S1):** creating the row requires a **fresh A3
assertion** for that XID and a consent-log entry
(`action = add_device`). It does **not** require an Elect
signature. At C2 signup the user's Elect key is generated and
dropped; a passkey-only friend cannot produce Elect. `authorize_elect`
gates XID document writes only. This matches how
`migrate_c2_to_c3` already treats the C2 consent artifact
(A3/A4 proof + consent-log).

**Custody honesty:** the git private key is host-custodied
C1-style material, like the Buzz nsec. Mjolnir root can sign as
the friend. Revoke is three places: opaque delete,
`revoke_device`, Forgejo key delete.

Rejected:

- A second Sign key on the C2 XID (`add_key` Sign)
- Elect-gated device insert (unprovisionable for a passkey-only
  C2 friend)
- Overloading `identikey_auth` for an SSH git pubkey
- A Forgejo deploy key with no identikey row

## Decision 4 — Forgejo on mimir is the write remote

`hypersigil-store-frontend` already has:

- `origin` → `github.com:aetherpunk108/hypersigil-store-frontend`
  (no deploy workflow)
- `forgejo` → `mimir.worldtree.network:VirtueInnova/hypersigil-store-frontend`
  (`.forgejo/workflows/deploy.yml` on `main`, `ENABLE_DEPLOY`)

The VM's `git push` target is Forgejo. GitHub stays a human
mirror if someone wants it. CI remains Forgejo Actions in a
Mjolnir VM, `mj deploy` `hypersigil-store`.

**Accepted risk:** `git push main` from grok is the prod cutover.
No extra gate in v1. A Forgejo branch rule is a later change.

## Decision 5 — Ticket URL for v1 preview; prod API; per-ticket CORS

Guest HTTP is already `https://<ticket>.vm.worldtree.network`.
Vite binds `0.0.0.0` in the guest. Frontend env is
`VITE_MEDUSA_BACKEND_URL=https://api.hypersigil.world` (same
publishable key as `mjolnir.toml`). Prod Medusa CORS lists that
**exact ticket origin** (`update-hypersigil-store-cors`). No
`*.vm.worldtree.network` wildcard (every VM on mimir would then
call prod).

Per-ticket CORS goes stale on respawn unless the ticket is
preserved (Decision 7). Named subdomain (v2) is what makes CORS
stable without `preserve_iroh_key`.

If Vite websocket fails through the gateway, document it; do not
block first paint.

## Decision 6 — ubuntu-24.04 bootstrap, not a new @base

ADR 0009: `@base/` is OS roots, not toolchains. The being clones
`ubuntu-24.04`, then a **per-friend snapshot** `hosted-<xid>` of
the grok+bun+git bootstrap (not a catalog entry; living
base-images already covers "Snapshot is not a catalog entry").
Do not declare `@base/hosted`.

Clone the repo **inside** the guest. `extra_mounts` is still
ignored (`mjolnir-gge.1.9`). wrug `/term` + `mj connect --session
main` is the human/grok shared TTY. Do not rebuild web-pty.

## Decision 7 — Respawn is a new device; URL held by per-friend snapshot

`spawn/1` mints a fresh `vm_id`. `_opaque/vms/<id>/` is keyed by
that id. v1 rule **(a):** a new VM is a **new device** — new SSH
key, new `ssh_git` credentials row, new Forgejo key; old device
revoked (opaque delete + `revoke_device` + Forgejo delete).

The ticket URL (and therefore the CORS entry) is held by
`preserve_iroh_key: true` on spawn from the **per-friend**
snapshot `hosted-<xid>`. Do not preserve Iroh identity from a
shared bootstrap snapshot (two VMs would share one node id).

Rejected: copying `_opaque/vms/<old>/` onto `<new>` and
re-registering nothing.

## Built vs remaining

Built: Cloud Hypervisor spawn, Iroh ticket URL,
`preserve_iroh_key`, wrug `/term` + cookie JWT, Keycloak
device-flow stand-in, identikey-core passkey OP at
`auth.identikey.me` (discovery 200), opaque VM inject for buzz
nsec, `owner_id` + `authorize_vm`, Forgejo deploy.yml, prod
storefront and API.

Not built: `ssh_git` kind + migration, A3 `add_device` consent,
SSH git key inject, Forgejo write registration, grok/bun/vite
bootstrap, wrug cutover to `auth.identikey.me`, preview CORS,
`owner_id` = public XID `sub`.

Remaining: the five implement landings. This change folds the
ADR only.

## Advise

Reader is Fable 5.1 (`architecture-review`). Same-family Grok
cannot sole-accept (ADR-005). First pass: send-back
2026-09-10. This amend answers S1–S4. Re-advise before act.
