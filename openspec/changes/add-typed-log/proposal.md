# add-typed-log

> **ACTIVE BUILD**

Activated from intend 2026-09-10 (`typed-log` / `nod-log-architecture`,
bead `mjolnir-t28i`). Human: activate all; remaining steer forks
took the recommended options (`steer.md`).

**Rigor:** architecture

## Why

Apps (myscape first) need a typed log that is pretty on a TTY, plain
ASCII in CI, and durable on syslog so any Mjolnir node can subscribe.
Guest syslog-over-vsock already exists for `/dev/log`. It does not
give TypeScript a library, a type file, or a host-side path for a
process that is not a guest. Without one record shape, pretty, LSP,
and EventBus each invent a dialect.

## What

- Add capability `typed-log`: MIT npm package `mjolnir-log` (bun
  native) emits pino JSON on stdout (default) and syslog (always);
  originating app ships TypeScript types; a generate step writes
  JSON Schema; pretty colors parsed fields; `--plain` / `NO_COLOR`
  is ASCII; LSP later uses the same schema.
- Accept ADR 0010 (`docs/decisions/0010-typed-log.md`, argument in
  `design.md`).
- This change is the architecture write. Code is later landings
  after advise accept: `add-log-emit`, `add-log-ingest`,
  `add-log-subscribe`, `add-log-lsp`, `add-myscape-log-types`.

## Impact

- Capabilities: ADDED `typed-log` (living spec only when an
  implementing act has landed — not this architecture fold)
- ADRs: 0010 (this change). Pointer from `docs/architecture.md`
  after the amendment boxes below.
- Does not replace `Mjolnir.Syslog` vsock ch2. Host **UDP**
  (loopback; `10.200.0.1` from guests) is an additional Listener
  source. Unix datagram is not the emitter path (bun has no
  AF_UNIX dgram).
- Does not add Phoenix.PubSub.

## User journey & surfaces

No new UI because the outcome already reaches stdout, syslog, and
`EventBus.subscribe/1`. An editor LSP is `add-log-lsp`.

Developer in myscape logs `world.asset_failed({ url, status })`.

- **Working (after later act)** — TTY shows a colored typed line;
  CI is plain ASCII; syslog carries the JSON MSG; an Elixir process
  subscribed to `:all` or the app id receives `{:mjolnir_event, id, :app_log, record}`.
- **Empty** — `openspec/specs/typed-log/` does not exist yet.
  Correct: fold of an *implementing* change (`add-log-emit` /
  `add-log-ingest`) creates it. This architecture change folds
  only the ADR (learning 2026-08-16).
- **Failed (today)** — ad-hoc `console` / in-process rings; guest
  syslog is RFC 3164 text only; host apps never hit EventBus.
- **Off** — Duke parks. ADR is amended in place, not deleted.

## Out of scope

- pino package implementation — `add-log-emit`
- Host UDP listener + RFC 3164 JSON MSG parse + ch2 register —
  `add-log-ingest`
- Subscribe helper / topic docs — `add-log-subscribe`
- Language server — `add-log-lsp`
- Myscape type file + wiring — `add-myscape-log-types`
- Phoenix.PubSub or an external broker
- Replacing web3d-space `src/lib/log.ts` until myscape/web3d adopts
- Log shipping SaaS, Loki, OpenTelemetry collector
- Changing guest vsock channel 2 assignment
