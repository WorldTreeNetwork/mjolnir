# add-buzz-local-runtime

> **ACTIVE BUILD**

Activated 2026-09-10. Bead `mjolnir-e70.3`. Split: B0 hive is
`add-buzz-relay` (`mjolnir-gti`) — **live**.

**Rigor:** change

## Why

`add-buzz-local-client` folded the fabric decisions and the slices
that are true in code. The leftover bag still named a self-hosted
relay and `@base/dev`. The codebase moved: ADR 0009 catalog is
`ubuntu-24.04` / `ci-ubuntu-24.04` / `buzz-agent` / `arch` — there
is no `@base/dev`. The community relay is running
(`wss://buzz.identikey.me`, app `buzz-relay`, NIP-OA closed,
snapshot `buzz-relay-b0`). This change is only the host-side
runtime that is still unbuilt: protocol facade, wake producer,
portable admit crate.

## What

- MODIFIED `buzz-local-client`: keep facade + wake-producer +
  identikey-protocol admit crate. Drop `@base/dev` (use the
  catalog). Relay / NIP-OA / provider-deployed identity stay on
  `add-buzz-relay` (already ACTIVE BUILD, hive live).
- `Mjolnir.Admit` v1 shape-check remains the evaluator until the
  crate lands.

## Impact

- Capabilities: MODIFIED `buzz-local-client`
- ADRs: none (0002 already). Catalog names from 0009.

## User journey & surfaces

Duke, Buzz desktop + `mj` against `https://api.vm.worldtree.network`.

- **Join hive** — Working: Desktop Join `wss://buzz.identikey.me`
  (looked 2026-09-10). Event log is the relay in the guest, not
  the host mailbox.
- **Running body, mention on Nostr** — Working for a live
  `buzz-acp` attached to that relay; host mailbox is not in that
  path.
- **Dormant body, mention wakes** — Failed/off: no host Nostr
  facade; wake producer is not the ingress.
- **Admit crate** — Empty in `identikey-protocol`; Mjolnir-local
  `Admit` shape-check is the stand-in.
- **Off** — Duke parks. Hive stays; this change does not unplug it.

No new UI because Join, mailbox, and `Admit` already exist.

## Out of scope

- Re-litigating ADR 0002
- Running or restoring the B0 hive — `add-buzz-relay` /
  `docs/runbooks/buzz-relay-restore.md`
- Creating `@base/dev` (catalog replaced it)
- Hosted Buzz product (`mjolnir-80q`)
- Recrypt, wallet custody, snapshot-resume as auto-wake
- Provider `deploy` op — `buzz-backend-mjolnir`
