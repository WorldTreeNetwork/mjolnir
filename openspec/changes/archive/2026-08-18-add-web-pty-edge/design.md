# Design — foreign web-PTY edge

Canonical ADR index: [`docs/decisions/0004-web-pty-edge.md`](../../../docs/decisions/0004-web-pty-edge.md).
This file is the full argument.

**Status:** Proposed — awaiting advise (activated 2026-08-18, Design A).
**Change:** `add-web-pty-edge`
**First consumer:** xibu `/devterm4` (`mjolnir-cid`)
**Implement after accept:** brief `nod-devterm4-stand`. No Mjolnir
API change.

## Problem

Four questions were still open after intend:

1. What protocol carries PTY bytes from a trusted Linux box to a
   Mjolnir VM?
2. Where does the Mjolnir JWT live, if a browser cannot set
   `Authorization` on `WebSocket`?
3. Does xibu grow a new WS-to-WS proxy, wrap `mj connect` in ttyd,
   or send people to Mjolnir's hosted `/term/:id`?
4. Does Mjolnir grow a tokenless PTY socket so the dashboard can
   connect without a header?

Guessing any of these in a systemd unit makes the first `/devterm4`
the architecture.

## What already exists

Mjolnir already has two attach paths. Neither is missing a wire
format.

**WebSocket PTY** (`mj connect <vm_id>`):

- URL: `wss://<api>/api/vms/:id/pty` (`router.ex` `get "/api/vms/:id/pty"`).
- Auth: `pty:connect`. JWT from `Authorization: Bearer`, then
  `?token=`, then the `mj_term` cookie (`auth.ex`). Sites tokens
  are refused on this path.
- Frames: binary = PTY stdin/stdout; text =
  `{"type":"resize","rows":N,"cols":N}` (`pty_handler.ex`).
- Optional `?session=` attaches a shared guest tmux.
- `mj` sets the Bearer header from `~/.config/mjolnir/token.json`
  (`connect.rs`).

**Iroh QUIC** (`mj connect <ticket>`): ALPN `mjolnir-shell/1`,
length-prefixed binary frames (Data/Resize/Exit/Hello). That path
is for P2P / NAT. xibu→`api.vm.worldtree.network` is a stable
server path; Iroh is the wrong hop.

**Hosted browser term** (`GET /term/:id`): same-origin xterm.js.
Stashes `?token=` into `mj_term` and redirects so the JWT is not
left in the URL (`term_page.ex`). Works only when the page and the
PTY socket share a host.

**xibu today:** three ttyd units on `127.0.0.1:7681-7683`, nginx
on 443 injects HTTP Basic and compositor JS. Standing rule (xibu
plan 29): never weaken ttyd basic-auth, never put those creds in
client JS, never proxy ttyd's WebSocket through the node app.
`mj` is already at `/usr/local/bin/mj` (profile
`https://api.vm.worldtree.network`) and has **no token**.

## Decision 1 — S2S is the existing PTY WebSocket

The hop from the trusted box to Mjolnir is:

```
wss://<api>/api/vms/<id>/pty[?session=<name>]
Authorization: Bearer <jwt>
```

Binary frames stay raw PTY bytes. Text frames stay resize JSON.
No new type byte, no second ALPN, no SSH subsystem.

Rejected as the *first* hop:

| Alternative | Why not |
|---|---|
| Iroh `mjolnir-shell/1` | P2P/NAT path. Extra endpoint + ticket. No win on a stable server path. |
| `mj ssh` / sshd in the guest | Works. Extra handshake, extra daemon, extra key story. Keep for humans who already want SSH. |
| Raw vsock | Only on the hypervisor host. xibu is not that host. |
| New framing (ttyd protocol to Mjolnir, or a custom JSON PTY) | Second codec. `mj connect` already speaks the one we have. |

## Decision 2 — The browser never holds the Mjolnir JWT

A foreign-origin page cannot use `mj_term` (different host,
`SameSite=Lax`, `Secure`). Putting the JWT in query, localStorage,
or compositor JS is how it leaks into VR mirrors and git.

The trusted edge holds the token (`mj login` →
`~/.config/mjolnir/token.json`). The browser authenticates to
*that* box (existing ttyd/nginx basic), not to Mjolnir.

Mjolnir SHALL NOT grow a tokenless PTY WebSocket to make the
dashboard's job easier. Loopback bypass stays loopback. Sites
tokens stay off this path.

## Decision 3 — Design A: local web PTY runs `mj connect`

```
Browser
  → nginx (TLS + existing basic-auth inject)
  → ttyd on 127.0.0.1 (new unit, new base path /devterm4)
  → tmux session (drop = detach, reload = attach)
  → mj connect <vm_id> [--session main]
  → wss://api.vm.worldtree.network/api/vms/<id>/pty + Bearer
  → PtyHandler → vsock → guest PTY
```

This is the same shape as `/devterm`–`/devterm3`. Compositor JS
inject keeps working. Plan 29 is untouched: we do not proxy
ttyd's socket through node.

Cost: double PTY (ttyd's local PTY wraps `mj`'s raw mode).
Accept it. One extra hop of bytes is cheaper than a new service
and a second auth story.

## Decision 4 — Designs B and C are rejected

**B — WS-to-WS proxy.** Browser xterm speaks Mjolnir's binary +
resize protocol; a local process adds Bearer. One PTY, no ttyd.
Rejected for v1: new binary, new systemd unit, compositor inject
does not come for free, and it is exactly the "proxy the terminal
WebSocket through an app" pattern plan 29 forbids if the app is
the dashboard. Close `mjolnir-8rr`.

**C — Hosted `/term/:id`.** Skip xibu's terminal. Cookie auth
works on the Mjolnir origin. Rejected as the *xibu* surface: you
lose compositor, layers, same-origin iframe, and the three-term
family. The page stays for people who already go to Mjolnir.

## Decision 5 — This change does not ship a unit

Architecture artifacts only. The first live `/devterm4` is
`mjolnir-cid` (brief): systemd, nginx location, `mj login`, a
wrapper that runs `mj connect` against one dedicated VM.

v1 is one VM, one tmux session name. A picker is a later brief.

## Consequences

- `PtyHandler` and `/api/vms/:id/pty` do not change.
- A dashboard change that fetches a Mjolnir JWT into the browser
  is a defect against this ADR.
- A Mjolnir change that accepts a PTY upgrade with no credential
  (except the existing loopback bypass) is a defect.
- xibu `mj list` staying 401 is an ops hole on the brief, not a
  reason to skip the token.

## Alternatives rejected

| Alternative | Why not |
|---|---|
| Token in `?token=` on a cross-origin WS | JWT in the URL, logs, Referer |
| CORS + cookie on `api.vm.worldtree.network` | Cross-site cookie for a shell. Worse than a local token. |
| Node/dashboard proxies Mjolnir PTY | Bypasses ttyd basic; plan 29; JWT in the node process next to every other app |
| ttyd talks Iroh | Ticket + relay for a box that can already reach the API |

## Open (do not block this ADR)

- Which VM id `/devterm4` attaches to (spawn one, or pin an
  existing id) — the brief picks.
- ttyd credential for #4 (own creds like #3, or shared with #1/#2)
  — ops, not the protocol.
- Whether `mj connect` uses `--session main` so the in-VM agent
  can share the same tmux — recommended yes; brief confirms.
