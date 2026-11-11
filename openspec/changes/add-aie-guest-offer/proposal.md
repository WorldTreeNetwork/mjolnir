# add-aie-guest-offer

> **ACTIVE BUILD**

Bead `mjolnir-io3b.6`. **Rigor:** change. Group: weave (with
folded `add-aie-host-sidecar`).
Activated 2026-11-11 by named `activate` on pin
`mjolnir-io3b` after sidecar closed. Not “and run”.
Architecture `add-aie-compute` / ADR 0015 accepted
(`reviews/2026-11-11-advise-4.md`).

**Preparation (2026-11-11):** still valid against ADR 0015
Decision 4 guest slice. Upstream: sidecar folded (`b481aea`,
archive `2026-11-11-add-aie-host-sidecar`); occupancy spike go
(`798a94b`); keyspace `63a9c9f` / `25f5cf4`; guild `b7c4842` /
`c42cd88`. Locator `aie_url` is living. Sidecar already serves
`POST {aie_url}/v1/execute` (`design_id`, optional `pending_id`).
`Mjolnir.Aie.Offer.mint/2` copies incarnation only; this node
mints holder-checked `mjolnir/aie-execute/v1` biscuit bytes.
Authority: named activate of this dependency-ready node only.
Not “and run”. Parent architecture stays inflight until this
landing.

## Why

The sidecar, offer leaf, and guild admit exist. The locator
already has `POST /v1/execute`. Guests still have no `mj`
share/run verb, no minted execute biscuit, and no client retry
of a live `pending_id`. Easy share is the product ask.

## What

- `mj compute share` / `mj compute run` (VM being is principal).
- HTTP execute is `POST {aie_url}/v1/execute`: catalog `design_id`
  + bounded input. Not OpenAI chat-completions (v1 job is a host
  catalog id). Retry body carries the same `pending_id`.
- Guest retries the same `pending_id` while the occupancy
  attempt is live; abandonment requires a fresh nonce.
- Mint copies current leaf incarnation onto
  `right("<owner_fp>/<offer_id>/<incarnation>", "aie-execute")`.
- Third identity without a grant is 403. No guest `/dev/accel`.

## Impact

- Capabilities: implements inflight `aie-compute` (guest
  surface); living spec already has sidecar/keyspace/guild
- ADRs: 0015 remaining child
- Living `aie-compute` on fold of this node, then parent

## User journey & surfaces

- **Working** — allowlisted VM being publishes; `mj compute
  share`; a second identity `mj compute run`s a catalog job via
  `aie_url`; guest has no `/dev/accel`.
- **Empty** — no `mj compute`; locator unused by clients.
- **Failed** — host process is the offerer; OpenAI-compat
  invented as the v1 job; guest retries after abandon with the
  old `pending_id` and loads.
- **Off** — no `aie_url`; run refuses.

## Out of scope

- Sidecar unit / admit / occupancy — folded `add-aie-host-sidecar`
- Offer leaf codec — folded `add-aie-keyspace-claims`
- Guild inject / `aie_delegate` — folded `add-guild-compute-holder`
- Fold of architecture `add-aie-compute` before this landing
- VFIO / virtio-accel / `mjolnir-03x`
- OpenAI-compat chat API (deferred; not v1)
