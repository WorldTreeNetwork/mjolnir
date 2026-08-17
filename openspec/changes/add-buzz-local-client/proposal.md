# add-buzz-local-client

> **ACTIVE BUILD**

## Why

The local Buzz client — desktop on the Mac, talking to a relay we host, deploying
agents into Mjolnir VMs — is stuck at design. `buzz-backend-mjolnir` answers
`info` and refuses `deploy`. Wake-on-message will thaw a body for any
`POST /api/vms/:id/messages`, which violates Buzz I5 if a mention is the
trigger. This change records the fabric decisions so later nodes can
implement without re-litigating mailbox vs Nostr, where admission lives, or
what the Postgres sidecar is for.

## What

- Add capability `buzz-local-client`: admit-then-thaw, OTP mailboxes as the
  body-control queue, Nostr as the Buzz event log, host sidecar as
  control-plane catalog, `@base/dev` as the human+CI image.
- Accept ADR 0002 (`docs/decisions/0002-buzz-local-client-fabric.md`, full
  text in `design.md`).
- Do not implement deploy, the admit crate, the relay VM, or desktop
  pointing in this change.

## Impact

- Capabilities: ADDED `buzz-local-client`
- ADRs: `docs/decisions/0002-buzz-local-client-fabric.md` (new). Pointer
  from `docs/architecture.md`. Does not rewrite ADR 0001 (CDN).

## User journey & surfaces

Duke, from the **Buzz desktop** (local fork
`~/work/IdentiKey/buzz`, branch `fix/remote-agent-presence-liveness`) on the
Mac.

1. Desktop opens and has an identity. **Today: works** (stock desktop).
2. Joined to a community whose relay we host. **Today: off** (no self-hosted
   relay; Block-hosted refuses provider-deployed identity).
3. Settings lists provider `mjolnir` from `/usr/local/bin/buzz-backend-mjolnir`.
   **Today: failed** (binary not installed; `deploy` refuses).
4. Deploy creates one `@base/buzz-agent` VM, harness is the signal-receiving
   process, `restart_policy=never`. **Today: failed**.
5. A mention in a channel gets a reply. **Today: off**.
6. `!shutdown` leaves the body down. A second mention does **not** thaw it.
   **Today: off** (and the current `deliver_message` path would thaw it).

Other surfaces the same journey already reaches: `mj` (spawn/list/message/doctor),
the Mjolnir HTTP API on the host, vsock `deliver_message`, `EventBus`, the
gateway URL. No new desktop chrome. No new `mj` verb in this change.

## Out of scope

- Implementing `deploy` — intend `nod-deploy-happy` / bead `mjolnir-e70` child
- Secret inject + negative nsec test — `nod-secret-inject` / `mjolnir-1pe`
- Self-hosted relay VM — `nod-local-relay` / `mjolnir-gti`
- `identikey-admit` crate — `nod-identikey-admit` in `identikey-protocol`
- Mailbox control code — `nod-mailbox-control`
- Sidecar role/DB tightening — `nod-sidecar-tighten`
- `@base/dev` image build — `nod-base-dev`
- Desktop rebase of #5138 — `nod-rebase-desktop-pr` / `mjolnir-ceo`
- Provider install to `/usr/local/bin` — `nod-install-provider`
- Graceful drain — `nod-graceful-stop` / `mjolnir-a5t`
- Hosted Buzz product, recrypt, IdentiKey wallet custody, snapshot-resume as
  auto-wake, replacing Nostr in the desktop, Distributed Erlang to guests
- CDN fan-out (Bunny) — same plugin *shape*, later; ADR 0001 still owns edge
