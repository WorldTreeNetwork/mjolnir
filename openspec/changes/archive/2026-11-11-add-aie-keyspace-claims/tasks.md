# Tasks

- [x] Offer leaf type + canonical bytes in SecretStore
- [x] Store `owner_fp` and being Ed25519 pubkey
- [x] Incarnation = Blake3 of signed leaf; mint copies current
- [x] Sequence + tombstone floor; refuse re-put of retired bytes
- [x] Allowlist of offering VM ids at publish and mint
- [x] Spawn does not mint a capacity asset
- [x] Close architecture scenarios: Capacity is a signed keyspace claim

## Out of scope

- Sidecar / admit — `add-aie-host-sidecar`
- Guild inject — `add-guild-compute-holder`
- `mj` share verb — `add-aie-guest-offer`
