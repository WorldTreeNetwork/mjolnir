# add-web-pty-edge

> **ACTIVE BUILD**

Activated from `nod-lock-edge-pty` (`mjolnir-alu`). Human picked
**Design A** in chat (2026-08-18): ttyd on the trusted edge runs
`mj connect`. Not a new proxy binary. Not Mjolnir's hosted `/term/:id`
as the xibu surface.

**Rigor:** architecture

## Why

A browser on the xibu dashboard cannot open Mjolnir's PTY WebSocket.
`new WebSocket(...)` cannot set `Authorization`. Mjolnir already
solved that for its *own* origin (`GET /term/:id` stashes a JWT in
the `mj_term` cookie). A foreign origin does not get that cookie.
Inventing a second PTY framing, or a tokenless public socket, would
put the JWT in JS or punch a hole in `pty:connect`. The attach path
has to be decided before `/devterm4` is wired, or the first ttyd
unit becomes the architecture.

## What

- ADR 0004: a foreign web terminal terminates on a trusted Linux
  box. That box opens the existing authenticated PTY WebSocket
  (`wss://<api>/api/vms/:id/pty`) with `Authorization: Bearer`.
  Wire format is unchanged: binary frames are raw PTY bytes; text
  frames are `{"type":"resize","rows":N,"cols":N}`. Optional
  `?session=` attaches a shared guest tmux.
- Design A is the edge: a local web PTY (ttyd, same family as
  `/devterm`–`/devterm3`) runs `mj connect`. The browser talks to
  ttyd. `mj` holds the token.
- Capability `web-pty-edge` (ADDED). Materialized by fold, not by
  this proposal existing.
- Hosted `/term/:id` stays for same-origin Mjolnir browsers. It is
  not the xibu surface.

## Impact

- Capabilities: ADDED `web-pty-edge` (materialized by fold)
- ADRs: 0004 (this change)
- Mjolnir API and `PtyHandler` are unchanged
- Living specs: no MODIFIED of `buzz-local-client`

## User journey & surfaces

Operator on the xibu dashboard (today: `https://dreamballz.com/devterm/`
and `/devterm2/`, `/devterm3/`) opens **`/devterm4/`** and reaches a
Mjolnir VM shell. Auth is the same family as the other three
terminals (nginx + ttyd basic). The browser never speaks to
`api.vm.worldtree.network`.

- **Empty** — `/devterm4` does not exist. `openspec/specs/web-pty-edge/`
  does not exist. Correct: the brief (`mjolnir-cid`) stands the
  unit up after advise accept; fold creates the living spec.
- **Working (after the brief)** — reload reattaches via tmux the
  way `/devterm` does; `mj connect` is still the S2S hop.
- **Failed** — browser JS holds a Mjolnir JWT; a later change adds
  a tokenless `/pty`; ttyd's WebSocket is proxied through the node
  app (xibu plan 29 forbids that).
- **Off** — Duke parks `/devterm4`. The ADR is amended in place,
  not deleted. `/term/:id` is unaffected.

## Out of scope

- Standing up ttyd4 / nginx `/devterm4` / `mj login` on xibu —
  brief `nod-devterm4-stand` (`mjolnir-cid`)
- WS-to-WS proxy binary — Design B, rejected; close `mjolnir-8rr`
- Replacing or widening `/term/:id` and the `mj_term` cookie
- Iroh QUIC (`mjolnir-shell/1`) as the xibu→API hop
- SSH / `mj ssh` as the xibu→API hop
- Multi-VM picker, spawn-on-connect, VR compositor changes
- Weakening ttyd basic-auth or putting those creds in client JS
- New PTY framing on vsock or WebSocket
