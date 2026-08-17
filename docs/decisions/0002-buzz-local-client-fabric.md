# ADR 0002 — Local Buzz client fabric

**Status:** Accepted (2026-08-16)
**Change:** [`add-buzz-local-client`](../../openspec/changes/add-buzz-local-client/proposal.md)
**Epic:** `mjolnir-e70`

Full argument: [`openspec/changes/add-buzz-local-client/design.md`](../../openspec/changes/add-buzz-local-client/design.md).

## One screen

1. **OTP mailboxes** are the host queue (0MQ patterns, not libzmq). **Nostr**
   is the Buzz event log. Not a chat-bridge.
2. **Guests do not join Distributed Erlang.** Span is vsock, Iroh, gateway.
3. **Admit, then thaw.** OpenResty-shaped plugins on the host; junk never
   hits `DormantRegistry`.
4. **Admission crate** lives in **identikey-protocol** (permissive), not
   identikey-core (AGPL).
5. **Host Postgres sidecar** is a control-plane catalog. Buzz/tenant data
   lives in the guest. PGlite is in-guest for `@base/dev` only.
6. **Dev = CI = `@base/dev`**. Prod differs by image contents, not by a
   second orchestrator.
7. **Relay** is a Mjolnir VM (`mjolnir-gti`). Join policy accepts
   provider-deployed identity. Compose-on-Mac is an on-ramp, not the design.
8. **CDN** (ADR 0001 / Bunny) is the same plugin shape at HTTP. Not this
   change.

## Do not implement from this file

Implementation is later intend nodes (`nod-identikey-admit`,
`nod-mailbox-control`, `nod-local-relay`, `nod-deploy-happy`, …).
