# add-log-subscribe

> **ACTIVE BUILD**

**Rigor:** change
**Bead:** `mjolnir-14qv`

## Why

`:all` EventBus subscribers receive `:app_log` and VM events.
Log-only consumers need `subscribe_logs/1` on distinct `:pg` groups.

## What

- `EventBus.subscribe_logs/1` and `unsubscribe_logs/1`
- `:app_log` also fans out to `{:app_log, id}` and `:app_log_all`
- App id is self-asserted (documented)

## Impact

- Capabilities: MODIFIED `typed-log`
- ADRs: none

## User journey & surfaces

No new UI because the outcome already reaches OTP `receive`.

## Out of scope

- Phoenix.PubSub
- LSP
