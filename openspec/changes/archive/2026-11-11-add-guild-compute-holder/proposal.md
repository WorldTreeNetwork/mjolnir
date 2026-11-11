# add-guild-compute-holder

> **ACTIVE BUILD**

Bead `mjolnir-io3b.4`. **Rigor:** architecture. Group: human-gate.
Activated 2026-11-11 by campaign grant on `mjolnir-io3b`
("activate"; not "and run"). Parent architecture
`add-aie-compute` recorded guilds-v1 as verifier inject
(Decision 6; Astra pass-4 accept). This node is no longer
provisional on that fork.

**Preparation (2026-11-11, R1–R8):** still valid. Astra pass-4
accept (`reviews/2026-11-11-advise-4.md`). Pins: grant/withdraw
profiles, pending selector, `aie_delegate` codec, single-record
floor. Authority: campaign grant on `mjolnir-io3b`. Sidecar flock
is sibling; occupancy spike go does not change this contract.

## Why

Guild-scoped AIE offers must fail-closed for strangers without
putting a human member key in the guest or changing Biscuit
authority-block crypto. The parent architecture named the
inject; the encoding and lookup client do not exist.

## What

- `mjolnir/aie-delegate/v1` current SecretStore leaf; guild-wide
  AIE execute; withdrawal is tombstone.
- Roster adapter: configured authority per guild; membership
  only; unconfigured fail-closed.
- `Mjolnir.Aie.Guild.admit/1` after try-lock; not Datalog
  `member` in `authorize`.
- Personal-fp offers skip lookup and delegation.
- identikey-capability guild-holder-on-the-token stays not v1.

## Impact

- Capabilities: implements inflight `aie-compute` guild clause;
  does **not** MODIFY identikey-capability "Guild holder class
  is not v1"
- ADRs: 0015 Decision 6
- Advise required (architecture)

## User journey & surfaces

No new UI because membership already lives in Recrypt/guild
rosters. Execute proof stays the consumer VM key.

- **Working** — guild member's delegation lets consumer VM H
  run; stranger is fail-closed; mint without a guild still works.
- **Empty** — no lookup client, no delegation type.
- **Failed** — Datalog membership in `mint`; human key required
  in the guest; enqueue-time membership authorizes load.
- **Off** — personal-fp offers still execute without this node.

## Out of scope

- Sidecar / occupancy / admit socket — `add-aie-host-sidecar`
- Offer leaf codec — `add-aie-keyspace-claims`
- `mj` verb — `add-aie-guest-offer`
- New Biscuit crypto / guild holder class on the token
- Recrypt roster product UI
