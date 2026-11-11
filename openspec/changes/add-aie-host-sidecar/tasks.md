# Tasks

- [x] Spike `aie-occupancy-lock` before act (`docs/spikes/aie-occupancy-lock/`) — go; worker inherits flock fd
- [x] Dedicated user/group `mjolnir-aie`; unit not root; accel node access
- [x] Bind `:host_api_ip:7422`, INPUT, fail-closed without dummy-mjolnir
- [x] Install on `just deploy` (no new just verb)
- [x] Locator map in `configure_identity`; inject/omit `aie_url`
- [x] BEAM `aie-admit.sock` listener + enqueue/admission-only pipeline
- [x] Pending table: `pending_id`, `attempt_id`, at-most-one load
- [x] IRON flock try-lock → admit → load or release; wall-time kill
- [x] Host catalog of design ids; refuse guest xclbin
- [x] Catalog footnote on `docs/guide/host-sidecars.md` → built
- [x] Close scenarios owned by this node in architecture `aie-compute` spec

## Out of scope

- `mj` verb / HTTP path — `add-aie-guest-offer`
- Offer leaf codec — `add-aie-keyspace-claims`
- Guild inject — `add-guild-compute-holder`
