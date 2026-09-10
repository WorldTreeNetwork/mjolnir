# ADR 0010 — Typed log (pino → syslog → EventBus)

**Status:** Proposed
**Date:** 2026-09-10
**Change:** [`add-typed-log`](../../openspec/changes/add-typed-log/proposal.md)
**Living spec (after fold):** [`openspec/specs/typed-log/spec.md`](../../openspec/specs/typed-log/spec.md)
**Epic:** `mjolnir-t28i`

Full argument:
[`openspec/changes/add-typed-log/design.md`](../../openspec/changes/add-typed-log/design.md).

## One screen

1. **MIT `mjolnir-log` in `packages/log`.** Bun for dev/build/runtime.
   Publish npm. Pino is the logger. Not a WorldTree checkout.
2. **Syslog is the wire.** Pino JSON is the MSG. Stdout default on;
   syslog always; no ANSI on the wire.
3. **Two ingest paths, one Router.** Guest `/dev/log` → vsock ch2
   stays. Host unix datagram for apps (myscape). EventBus `:app_log`
   vs existing `:vm_syslog`.
4. **`:pg` EventBus.** No Phoenix.PubSub. App id is the binary key.
5. **App TS types → generated JSON Schema.** Pretty and LSP consume
   that schema. Unknown fields kept, flagged.
6. **Code is later nodes.** `add-log-emit`, `add-log-ingest`,
   `add-log-subscribe`, `add-log-lsp`, `add-myscape-log-types`.

## Built vs remaining

Built: guest syslog pipeline (`lib/mjolnir/syslog/`, guest
`syslog.rs`).

Remaining: advise, then the five implement landings.
