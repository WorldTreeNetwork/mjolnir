## ADDED Requirements

### Requirement: VM being is the offer principal

An AIE offer SHALL be named by the sharing VM's IdentiKey. The
sidecar process SHALL NOT be the IdentiKey principal. Execute
SHALL authorize against that offer. When the named VM is gone,
execute for that offer SHALL be refused.

#### Scenario: Host process is not the offerer

- GIVEN a sidecar process running as `mjolnir-aie` on the host
- WHEN a client presents a token bound only to that process identity
- THEN execute is refused

#### Scenario: Missing being fails closed

- GIVEN an offer whose VM id is no longer running or dormant-restorable
- WHEN execute is presented for that offer
- THEN execute is refused
- AND the NPU program is not loaded

### Requirement: Guests execute on the locator with mj

The guest surface SHALL be HTTP on `aie_url` plus `mj compute
share` and `mj compute run`. v1 execute SHALL be
`POST {aie_url}/v1/execute` naming a host-catalog `design_id`
and bounded input bytes. It SHALL NOT be an OpenAI
chat-completions API. Mint SHALL copy the current offer
incarnation onto
`right("<owner_fp>/<offer_id>/<incarnation>", "aie-execute")`.
A caller who is not the holder and has no valid guild
delegation SHALL receive 403. Guests SHALL NOT receive
`/dev/accel` or `/dev/dri`. Overlay `aie_url` SHALL NOT be the
sole audience.

#### Scenario: Second identity runs

- GIVEN an allowlisted offering VM and a second identity in the
  grant set
- WHEN they `mj compute run` a catalog job
- THEN the client POSTs `{aie_url}/v1/execute` with that
  `design_id`
- AND the sidecar loads that catalog design after BEAM admit
- AND the guest still has no `/dev/accel`

#### Scenario: Third identity is 403

- GIVEN a third identity with no execute right and no member
  delegation
- WHEN they present execute
- THEN the response is 403
- AND the NPU program is not loaded

#### Scenario: Spawn does not mint

- GIVEN `mj spawn` of an allowlisted VM
- WHEN spawn completes
- THEN no execute token is minted
- AND no offer leaf is written by spawn

### Requirement: Guest retries a live pending_id

After enqueue returns `pending_id`, the guest or `mj` SHALL
retry that same id while the occupancy `attempt_id` is live.
After abandon, restart, cancel, or max queue age, the client
SHALL obtain a fresh nonce and enqueue again. Retries SHALL NOT
reset enqueue time.

#### Scenario: Lost reply retries the same pending_id

- GIVEN enqueue returned `pending_id` P and the occupancy
  attempt is still live
- WHEN the guest retries with P
- THEN at most one load starts
- AND a second design is not loaded

#### Scenario: Retry after abandon needs a new enqueue

- GIVEN P was abandoned (deadline, lock release, cancel, or restart)
- WHEN the guest retries P
- THEN load is not authorized
- AND a new execute requires a fresh nonce and a new `pending_id`
