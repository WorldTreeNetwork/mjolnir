# add-aie-keyspace-claims

> **ACTIVE BUILD**

Bead `mjolnir-io3b.7`. **Rigor:** change. Group: solo.
Activated 2026-11-11 by campaign grant on `mjolnir-io3b`
("activate"; not "and run"). Architecture
`add-aie-compute` / ADR 0015 accepted
(`reviews/2026-11-11-advise-4.md`).

**Preparation (2026-11-11):** still valid. Upstream architecture
pins canonical `{owner_fp, offer_id}` plus leaf-hash incarnation,
sequence + tombstone floor, operator allowlist, whole-offer
revocation. SecretStore today sniffs Head/Manifest/Alias only
(`lib/mjolnir/secret_store.ex`). Authority: campaign grant, this
dependency-ready node. Guild inject is sibling `add-guild-compute-holder`;
personal-fp offers land without it.

## Why

Execute rights name an offer incarnation. Spawn must not mint a
capacity asset. SecretStore has no AIE offer record type, no
sequence floor, and no being-pubkey field beside `owner_fp`.

## What

- Signed offer leaf under the owner's keyspace fingerprint.
- Store both `owner_fp` (path) and the being's 32-byte Ed25519
  pubkey (for §5 holder fp).
- Incarnation = Blake3 of canonical signed leaf bytes.
- Strictly increasing sequence; tombstone retained as floor;
  re-put of retired bytes refused.
- Publish/mint only when the named VM IdentiKey equals the
  keyspace owner **and** the VM id is on the host allowlist.
- v1 revocation is whole-offer replacement.

## Impact

- Capabilities: implements inflight `aie-compute` (offer leaf)
- ADRs: 0015 Decision 5
- Living `aie-compute` on architecture fold after landings

## User journey & surfaces

No new UI because publish is a signed keyspace put the owner
already performs (Sites/SecretStore). `mj` share verb is
`add-aie-guest-offer`.

- **Working** — owner publishes an allowlisted offer; mint copies
  the current incarnation; unsigned or other-being leaves refuse.
- **Empty** — no offer type in SecretStore.
- **Failed** — spawn writes an offer; two owners share one right
  for the same local `offer_id`; retired bytes resurrect a grant.
- **Off** — no leaf at the offer key; execute refuses.

## Out of scope

- Sidecar unit / admit / occupancy — `add-aie-host-sidecar`
- `mj` verb — `add-aie-guest-offer`
- `member(ks, pk)` inject — `add-guild-compute-holder`
- `--keyspace` on `mjolnir.publish` — `mjolnir-9bq.5`
- Recrypt MultiSig verify wiring if still stubbed (seam stays
  `verify_envelope/2`)
