## ADDED Requirements

### Requirement: Foreign-origin web terminals terminate on a trusted edge

A web terminal whose page is not served from the Mjolnir API origin
SHALL terminate the browser session on a trusted Linux box. That box
SHALL open the authenticated PTY WebSocket to Mjolnir. The browser
SHALL NOT open `wss://<mjolnir-api>/api/vms/:id/pty` itself.

#### Scenario: Dashboard terminal attaches

- GIVEN a browser on a foreign origin (a dashboard host)
- WHEN the operator opens the Mjolnir terminal surface
- THEN the browser's WebSocket target is the dashboard host
- AND a process on that host is the Mjolnir PTY client

#### Scenario: Browser talks to the API origin

- GIVEN a foreign-origin page
- WHEN it opens a WebSocket to the Mjolnir `/api/vms/:id/pty` URL
- THEN that is a defect against this requirement
- AND it is not the supported attach path

### Requirement: The server-to-server hop is the existing PTY WebSocket

The trusted edge SHALL attach with `mj connect` (or a client that
speaks the same hop): `wss://<api>/api/vms/:id/pty` with
`Authorization: Bearer`. Binary frames SHALL be raw PTY bytes.
Text frames SHALL be resize JSON of the form
`{"type":"resize","rows":N,"cols":N}`. A change that introduces a
second PTY framing for this hop SHALL be rejected.

#### Scenario: Edge process attaches

- GIVEN a logged-in `mj` on the trusted edge and a running VM
- WHEN the edge runs `mj connect <vm_id>`
- THEN it opens the PTY WebSocket with a Bearer header
- AND binary frames carry PTY I/O
- AND a resize is a text frame of that JSON shape

#### Scenario: A new PTY codec is proposed for the edge hop

- GIVEN a change that adds a second frame type or ALPN for
  xibu-to-API PTY bytes
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: The Mjolnir JWT stays off foreign-origin browser JS

The Mjolnir JWT used for `pty:connect` SHALL live on the trusted
edge (the `mj` token store). Foreign-origin pages SHALL NOT be given
that JWT in script, `localStorage`, or a query string intended for
the PTY socket.

#### Scenario: Compositor or dashboard JS is inspected

- GIVEN the foreign-origin terminal page and its injected scripts
- WHEN they are reviewed for credentials
- THEN they do not contain a Mjolnir JWT
- AND they do not fetch one for the browser to present to Mjolnir

### Requirement: Mjolnir does not expose a tokenless PTY WebSocket

`GET /api/vms/:id/pty` SHALL continue to require `pty:connect`.
A request with no JWT, no `mj_term` cookie, and no loopback bypass
SHALL NOT upgrade. Loopback bypass and the hosted `/term/:id`
cookie path SHALL stay as they are. They are not the foreign-origin
attach path.

#### Scenario: Unauthenticated upgrade from the internet

- GIVEN a client that is not loopback and presents no JWT or
  `mj_term` cookie
- WHEN it requests `GET /api/vms/:id/pty`
- THEN the upgrade is refused

### Requirement: The v1 edge is a local web PTY wrapping `mj connect`

The first foreign-origin surface SHALL be a local web terminal on
the trusted edge whose command is `mj connect` (optionally with a
guest tmux `--session`). It SHALL NOT be a new process that
forwards the browser's WebSocket to Mjolnir. It SHALL NOT replace
the hosted `/term/:id` page.

#### Scenario: v1 surface is wired

- GIVEN advise has accepted this change
- WHEN the follow-up brief lands the surface
- THEN a browser on the dashboard host reaches a Mjolnir VM PTY
- AND the process on the box that speaks to Mjolnir is `mj connect`
- AND `/term/:id` still exists for same-origin clients
