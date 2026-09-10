# add-log-ingest

> **ACTIVE BUILD**

Activated with the typed-log DAG. Depends on `add-typed-log`
amendment pins (`c40b93f`). Emitter is `add-log-emit` (`6c92643`).

**Rigor:** change
**Bead:** `mjolnir-vqpd`

## Why

`mjolnir-log` can send RFC 3164 UDP. Nothing on the BEAM listens.
Guest ch2 frames still hit "unregistered channel 2" and drop.
Without ingest, EventBus never sees `:app_log`.

## What

- Host UDP listener (loopback; guests may send to `10.200.0.1`).
- Register `Syslog.Listener` as vsock ch2 handler; identify sender
  when multiple VMs.
- Discriminator: MSG JSON with `schema` → `:app_log`; else
  `:vm_syslog`.
- 64 KiB max; oversize = malformed raw. `:app_log` sinks
  `[:eventbus]`. App id is self-asserted.

## Impact

- Capabilities: MODIFIED `typed-log` (ingest SHALLs)
- ADRs: none (0010)

## User journey & surfaces

No new UI because the outcome already reaches EventBus.

- **Working** — UDP 3164 JSON with `schema` arrives as
  `{:mjolnir_event, app, :app_log, record}`; guest text as
  `:vm_syslog`.
- **Empty** — no UDP socket; ch2 unregistered.
- **Failed** — frames dropped / malformed 5424.
- **Off** — syslog config unset on the emitter.

## Out of scope

- Pretty / pino package — `add-log-emit` (landed)
- Distinct `:pg` group vs `:all` mailbox load — `add-log-subscribe`
- LSP — `add-log-lsp`
- RFC 5424 header parse (v1 is 3164)
