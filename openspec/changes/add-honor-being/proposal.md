# add-honor-being

> **ACTIVE BUILD**

Activated from intend 2026-09-10 (`nod-honor-shape`, bead
`mjolnir-x97p.1`). Human: activate `.1`. Host picker declined;
remaining steer forks took the recommended options (`steer.md`).
Fable send-back 2026-09-10 (S1–S4) amended in place; re-advise
before act.

**Rigor:** architecture

## Why

A non-technical vibe coder needs a complete hosted dev environment
for `hypersigil-store-frontend`: grok in a VM, passkey login, a
preview URL, signed commits, and push that cuts over prod. Spawn
and wrug `/term` exist. They do not say whose identikey the machine
is, how grok relates to IdentiKey, or how a git-signing key is
bound to a C2 identity. Without that shape, later nodes invent
four different beings.

## What

- Add capability `honor-being`: a long-lived microVM that is a
  **device** of a friend's C2 managed identikey, not a second
  person and not a catalog OS root.
- Accept ADR 0011 (`docs/decisions/0011-honor-being.md`, argument
  in `design.md`).
- This change is the architecture write. Code is later landings
  after advise accept: `add-identikey-being-client`,
  `add-vm-git-subkey`, `add-honor-git-remote`,
  `add-honor-dev-preview`, `update-hypersigil-store-cors`.

## Impact

- Capabilities: ADDED `honor-being` (living spec only when an
  implementing act has landed — not this architecture fold)
- ADRs: 0011 (this change). Pointer from `docs/architecture.md`
  after advise accept.
- Does not add a `@base` name (ADR 0009). Does not grow
  Keycloak/`connect.identikey.io`. Does not make IdentiKey an
  xAI IdP. Does not put a second Sign key on the C2 XID. Does
  not Elect-gate the device row (A3 + consent-log). Does not
  wildcard `*.vm.worldtree.network` on prod CORS.

## User journey & surfaces

Friend (or Duke acting as the friend) opens the hosted-being environment
from a browser.

- **Working (after later act)** — passkey at
  `https://auth.identikey.me/authorize` opens wrug `/term` on tmux
  `session=main` (`owner_id` = friend's XID) with grok running on
  `XAI_API_KEY`; `mj url` is a Vite preview on
  `https://<ticket>.vm.worldtree.network` talking to
  `https://api.hypersigil.world`; grok commits are SSH-signed;
  `git push` to Forgejo `main` deploys `https://hypersigil.world`.
- **Empty** — `openspec/specs/honor-being/` does not exist yet.
  Correct: fold of an *implementing* change creates it. This
  architecture change folds only the ADR (learning 2026-08-16).
- **Failed (today)** — a VM can be spawned and `/term` can attach
  via Keycloak device-flow (wrug.3). There is no C2 device, no
  git subkey inject, no grok bootstrap, no preview pointed at
  prod, no Forgejo machine identity.
- **Off** — Duke parks. ADR is amended in place, not deleted.

## Out of scope

- Passkey client registration + wrug.3 cutover off Keycloak —
  `add-identikey-being-client` (`mjolnir-x97p.2`)
- Opaque SSH key inject + identikey device row —
  `add-vm-git-subkey` (`mjolnir-x97p.3`)
- Forgejo write key / machine user —
  `add-honor-git-remote` (`mjolnir-x97p.4`)
- grok + bun + clone + Vite on ticket URL —
  `add-honor-dev-preview` (`mjolnir-x97p.5`)
- Prod Medusa `STORE_CORS` / `AUTH_CORS` for the preview origin —
  `update-hypersigil-store-cors` (`mjolnir-x97p.6`)
- Prod hypersigil-store-backend deploy
- C3/C4 climb, A4 enclave login
- `GROK_OIDC_ISSUER` against identikey (no xAI proxy)
- New `@base/` flavor for grok
- GitHub Actions as the prod cutover
- Plumbing `extra_mounts` (`mjolnir-gge.1.9`) — clone inside the guest
- Named `*.vm.worldtree.network` subdomain (v2)
