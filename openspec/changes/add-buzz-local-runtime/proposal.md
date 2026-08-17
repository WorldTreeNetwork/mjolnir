# add-buzz-local-runtime

> **PENDING**

**Rigor:** change

## Why

`add-buzz-local-client` (archived
`openspec/changes/archive/2026-08-16-add-buzz-local-client/`) folded
the fabric *decisions* and the one implement slice that is true in
code (fail-closed thaw, `:never` refuses dormancy). The rest of the
local Buzz client — Nostr/Matrix ingress, identikey-protocol crate,
`@base/dev`, self-hosted relay, nsec inject — is not built. Living
specs must not claim it.

## What

- Carry the unimplemented SHALLs from `add-buzz-local-client` as this
  change’s deltas.
- Implement via existing beads: `mjolnir-gti`, `mjolnir-1pe`,
  `nod-identikey-admit`, `nod-base-dev`, Nostr ingress.

## Impact

- Capabilities: MODIFIED `buzz-local-client`
- ADRs: none (0002 already accepted)

## User journey & surfaces

Same six-step Buzz desktop journey as `add-buzz-local-client`. Steps
2–6 are still **off** / **failed**.

## Out of scope

- Re-litigating ADR 0002
- Hosted Buzz product (`mjolnir-80q`)
- Recrypt, wallet custody, snapshot-resume as auto-wake
