# Design — local Buzz client on the Mjolnir fabric

Canonical ADR index: [`docs/decisions/0002-buzz-local-client-fabric.md`](../../../../docs/decisions/0002-buzz-local-client-fabric.md).
This file is the full argument. The index entry exists so `docs/decisions/`
stays browsable.

**Status:** Accepted in chat (2026-08-16 dictation + activate).
**Change:** `add-buzz-local-client`
**Epic:** `mjolnir-e70`

## Problem

Three questions were still open after intend:

1. Is a Mjolnir mailbox a replacement for Nostr, or something else?
2. How do we thaw VMs for real work without thawing them for junk?
3. Where do databases and images live for a world where **dev is a VM**
   and **prod is a VM**?

Guessing any of these in `deploy` code makes the provider non-conforming
(I5) or turns the host sidecar into a tenant hotel.

## Decision 1 — OTP mailboxes are the queue; Nostr is the Buzz log

The host BEAM is a de facto universal message queue. Each VM already has a
GenServer: one mailbox, one lifetime, a supervisor, lookup by id. 0MQ
patterns (REQ/REP, PUB/SUB, ROUTER/DEALER, PUSH/PULL) map onto `:pg` +
GenServers. We take the *patterns*, not libzmq.

Nostr stays the Buzz event log: kinds, FTS, audit, desktop, `buzz-acp`.
A mention is a kind 9. “Thaw this body” is a *different* message, and it
only exists after admission says yes.

A selector that makes a Mjolnir-native agent appear in a Buzz channel
without `buzz-acp` is still later. This change does not build a Nostr↔MQ
chat bridge.

## Decision 2 — Guests do not join the Erlang cluster

The mailbox *abstraction* spans networks. Distributed Erlang does not
have to. EPMD-to-the-public-internet is a cookie away from root.

Network span is vsock (`deliver_message`), Iroh (operator + mesh), and
the gateway (HTTP). The BEAM stays on the host (or a trusted LAN).

`docs/architecture.md` already lists “Distributed by default” as an OTP
benefit. That remains true **between hosts we operate**, not between
host and guest.

## Decision 3 — Admit, then thaw (OpenResty for actors)

```
message in → admit (plugins) → drop / reply here / deliver_message (thaw)
```

The first process in the tree is a facade. Validity is decided *outside*
the guest, the way `ngx_lua` can 403 or serve cache without pinging
upstream.

Plugins are cheap predicates, not the application:

- signed IdentiKey envelope for this actor id
- provider drain / control for a `buzz.managed-by` body
- cache hit (same shape as a CDN origin decision)
- “this class of request is never a wake”

I5 falls out of the door: a mention that is not an admitted wake never
hits `deliver_message`, so `DormantRegistry` never runs. Wake-on-message
stays; it is no longer the public front door.

## Decision 4 — The facade is identikey-protocol, not identikey-core

Both repos are open. The split is license:

| Repo | License | Job |
|---|---|---|
| `identikey-protocol` | Apache-2.0 OR BSD-2-Clause-Patent | Embeddable formats and protocols |
| `identikey-core` | AGPL-3.0-or-later + commercial | Product platform (Keycloak, passkeys, JWTs) |

Admission is a protocol (admit / deny / forward). It must embed in
Mjolnir, a gateway plugin, and later a CDN edge without AGPL-infecting
the provider. New crate (working name `identikey-admit`) or an extension
of `identikey-auth`. Core may *use* it later as a Keycloak/passkey
plugin.

Tracked as intend `nod-identikey-admit`. Not built here.

## Decision 5 — Host Postgres sidecar is a catalog, not a hotel

Today: one Port-managed postgres, Unix socket, peer auth, roles
`mjolnir_admin` / `mjolnir_sites`, **derived indexes**. Filesystem is
source of truth. That contract stays.

The sidecar grows named databases for *host services* (`sites`, maybe
`admit`, maybe `forge`). It does not grow a database per VM, per tenant,
or per Buzz community.

- No guest network path to the sidecar socket.
- No “provision a DB for this VM” API.
- Buzz relay Postgres is the community event log → **inside the relay
  VM**, snapshotted with the rootfs, egressable as a file.

PGlite (Electric) is an **in-guest** default for `@base/dev` and CI:
postgres wire, no daemon, single-threaded, fine for one human or one
test. Not the host sidecar. Not the Buzz relay. Not a multi-writer
prod store. If a test needs concurrency, spawn real postgres *in that
VM*.

## Decision 6 — Dev box = test image = a Mjolnir VM

| Image | Who | Contents |
|---|---|---|
| `@base/dev` | Humans (`mj spawn`) and Forgejo CI | Toolchain, mise, git, guest agent, PGlite |
| `@base/buzz-agent` | Buzz bodies only | Baked sprig / `buzz-acp`, harness as PID 1 |
| Prod runtime | Deployed apps | App + agent, no toolchain |

Dev and prod differ by **image contents**, not by a second orchestrator.
`@base/ci-ubuntu-24.04` should converge on `@base/dev` so we stop
shipping a CI image that cannot boot (`mjolnir-0e8`).

## Decision 7 — Relay placement

The demo relay is a **Mjolnir VM** behind the gateway (`mjolnir-gti`).
That is the only place provider-deployed identity (desktop-minted nsec +
NIP-OA `auth_tag`) is guaranteed to work. Block-hosted communities
refuse that class (`block/buzz#2663`, 2026-08-05 correction).

Docker compose on the Mac is an allowed on-ramp if `RELAY_URL` is the
body’s lifetime bind (I3) and we can swap the URL later. It is not the
architecture.

Our relay’s join policy accepts the provider-deployed identity class.
The “plain member, no `auth_tag`” workaround stays non-default: it
kills `!shutdown`.

## Decision 8 — Provider install and secrets

- `buzz-backend-mjolnir` lives at `/usr/local/bin`, never inside the
  Tauri bundle (desktop discovery prepends the app dir).
- API credentials are ambient (`~/.config/mjolnir`, `mj login`). No
  `*_token` / `*_secret` field in `provider_config` (desktop lint).
- `nsec` is opaque. No curve math on our side. Injected over vsock.
  Never written to the VM record, API response, host logs, or syslog.

## Decision 10 — Wake producer is the protocol ingress (2026-08-16)

For Buzz, a wake is produced by **incoming traffic on the external
queue** — Nostr first, Matrix later. The host runs an emulation
layer: external event → internal OTP message (mailbox / broadcast /
0MQ-shaped patterns) → last hop back to a conformant Nostr event
for `buzz-acp`. The host is not a second event log.

A running harness still reads the relay directly. Dormant bodies
cannot; the ingress is what makes a mention *exist* as an internal
message the proxy can admit or drop.

v1 posture: a mention is a candidate wake only after that
translation and a proxy attestation. A `:stopped` `:never` body
still does not auto-resume; owner/provider Start is a different
topology.

## Decision 11 — Proxies attest; trusted deliver checks the stamp

The request path is: untrusted ingress → proxy (authorize, fail
closed) → signed attestation bound to VM + generation →
`deliver_message` / queue. The VM with the large application thaws
only for attested requests. `deliver_message/3` is the trusted hop,
not the public door — but it must reject a missing/invalid stamp so
vsock/MCP/CLI cannot skip the proxy.

## Decision 12 — The facade is not the only resurrection path

Request-based services usually go through the proxy. Operator
revive, Health, Reconcile under `restart_policy: always`, and later
snapshot-resume on owner Start are other topologies. The spec must
not pretend the facade is the only way a VM runs again. Buzz bodies
stay `:never`: Reconcile does not auto-resume; `signal_done` must
not park them in `DormantRegistry`.

## Decision 9 — CDN is the same plugin, later

Admit-or-serve-from-cache is the OpenResty plugin at HTTP layer. ADR
0001 already picked a CNAME pull-zone (Bunny first) in front of the
HTTP/1.1 gateway. This change does not implement a CDN. It forbids a
*second* admission design for cache vs thaw.

## Alternatives rejected

- **Replace Nostr with OTP for chat.** Throws away FTS, audit, desktop,
  and every Buzz client. We are not rewriting Slack.
- **Distributed Erlang into the guest.** Guests are Linux, not BEAM.
  Cookie = root.
- **Wake-on-message as the Buzz front door.** Convenient, non-conforming.
- **Auth facade in identikey-core.** AGPL on the mailbox path.
- **One host Postgres for Buzz + Sites + tenants.** Isolation is the
  product; the event log must snapshot and leave with the VM.
- **PGlite on the host** replacing the sidecar. Single-threaded, wrong
  trust boundary.
- **Separate “dev orchestrator”** (compose/k8s for humans, Mjolnir for
  prod). Defeats the fabric.

## Risks

- `identikey-admit` is a new crate in another repo. Until it exists,
  Mjolnir must not grow a one-off `if buzz` in `deliver_message` that
  becomes the real facade.
- Compose-on-Mac as a “temporary” relay becomes the demo. Time-box it
  or skip it.
- `@base/dev` vs leftover `@base/ci-ubuntu-24.04` drift. Converge or
  delete.

## Review

Authoring pass: Grok 4.6 (this file). Intend assigned the architecture
*reader* as Grok as well — same family as the author. A second-family
or human read is still owed before `act` on mailbox / admit / deploy.
Do not treat this file as self-approved.
