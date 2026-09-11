# ADR 0002 — Local Buzz client fabric

**Status:** Accepted (2026-08-16)
**Change:** [`add-buzz-local-client`](../../openspec/changes/archive/2026-08-16-add-buzz-local-client/proposal.md) (folded 2026-08-16)
**Living spec:** [`openspec/specs/buzz-local-client/spec.md`](../../openspec/specs/buzz-local-client/spec.md)
**Remaining:** B0 hive is
[`add-buzz-relay`](../../openspec/changes/add-buzz-relay/proposal.md)
(`wss://buzz.identikey.me`, live 2026-09-10). Runtime facade / wake
producer / admit crate folded 2026-09-10
([`add-buzz-local-runtime`](../../openspec/changes/archive/2026-09-10-add-buzz-local-runtime/proposal.md)).
**Epic:** `mjolnir-e70`

Full argument: [`openspec/changes/archive/2026-08-16-add-buzz-local-client/design.md`](../../openspec/changes/archive/2026-08-16-add-buzz-local-client/design.md).

## One screen

1. **OTP mailboxes** are the host queue (0MQ patterns, not libzmq).
2. **Protocol facade:** Nostr (later Matrix) → internal messages →
   conformant Nostr at a Buzz body. Host is not a second event log.
3. **Wake producer** for Buzz is that ingress, not the guest or Reconcile.
4. **Proxies attest; `deliver_message` is the trusted hop** and rejects
   unstamped thaws. Facade is the common *request* path, not the only
   resurrection topology.
5. **Guests do not join Distributed Erlang.**
6. **identikey-protocol** owns wire + validators; Mjolnir owns lifecycle.
   Fail closed. Verify ≠ custody.
7. **Host Postgres sidecar** is schemas in one catalog DB, not a hotel.
   **Superseded in part by [ADR 0005](0005-host-sidecar-tenant-hotel.md):**
   declared tenant apps MAY `CREATE DATABASE` in the same process;
   Buzz event logs still SHALL NOT. Item 7 as folded on 2026-08-16
   remains the living text until `add-host-sidecar-tenant` folds.
8. **Catalog images** (ADR 0009): spawn `ubuntu-24.04`, CI
   `ci-ubuntu-24.04`, Buzz bodies `buzz-agent`. **Relay** is a
   Mjolnir VM (`mjolnir-gti` / `add-buzz-relay`; hive live
   `wss://buzz.identikey.me`). `@base/dev` was never built.
9. **CDN** (ADR 0001) is the same plugin shape at HTTP. Not this change.

## Built vs remaining

Built (living spec): fail-closed `Mjolnir.Admit` shape-check, `:never`
refuses `DormantRegistry`, guests stay off the cluster, sidecar is
catalog-only, nsec is an opaque SecretStore blob injected over vsock
(`mjolnir-1pe`, 2026-08-17), Nostr protocol facade as named wake
producer (`Mjolnir.Buzz.Facade`), portable `identikey-admit` crate
(identikey-protocol `093ceb1`; no NIF; `Mjolnir.Admit` remains the v1
Elixir evaluator).

Remaining: B0 hive / NIP-OA is `add-buzz-relay`. Matrix ingress and
NIF linking are not built. Do not implement from this ADR.
