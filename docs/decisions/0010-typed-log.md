# ADR 0010 — Typed log (pino → syslog → EventBus)

**Status:** Accepted
**Date:** 2026-09-10
**Change:** [`add-typed-log`](../../openspec/changes/add-typed-log/proposal.md)
**Living spec (after fold):** [`openspec/specs/typed-log/spec.md`](../../openspec/specs/typed-log/spec.md)
**Epic:** `mjolnir-t28i`

Full argument:
[`openspec/changes/add-typed-log/design.md`](../../openspec/changes/add-typed-log/design.md).

## One screen

1. **MIT `mjolnir-log` in `packages/log`.** Bun for dev/build/runtime.
   Publish npm. Pino is the logger. Not a WorldTree checkout.
2. **Syslog is the wire.** Pino JSON is the MSG. v1 headers are
   RFC 3164. Stdout default on; UDP syslog when configured;
   no ANSI on the wire.
3. **Two ingest paths, one Router.** Guest `/dev/log` → vsock ch2
   stays (forwarder built; host ch2 register is ingest work).
   Host ingest is **UDP** (loopback; `10.200.0.1` from guests).
   `:app_log` iff MSG is JSON with `schema`; `source` is a stamp.
4. **`:pg` EventBus.** No Phoenix.PubSub. App id is self-asserted.
5. **App TS types → generated JSON Schema.** Pretty and LSP consume
   that schema. Unknown fields kept, flagged.
   LSP pin: bun bin `mjolnir-log-lsp` in `packages/log` (NDJSON
   diagnostics via `validateRecord`; `vscode-languageserver` +
   `jsonc-parser` are optionalDependencies, not imported by the
   logger entry).
6. **Code is later nodes.** `add-log-emit`, `add-log-ingest`,
   `add-log-subscribe`, `add-log-lsp`, `add-myscape-log-types`.

## Built vs remaining

Built: guest forwarder + RFC 3164 parser + Router/EventBus.

Not built: ch2 Listener registration, multi-VM sender id, host
UDP, `mjolnir-log`.

Remaining: the five implement landings. This change folds the ADR
only.
