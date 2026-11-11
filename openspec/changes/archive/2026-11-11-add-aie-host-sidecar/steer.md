# steer add-aie-host-sidecar

Inherited from `add-aie-compute` / `mjolnir-io3b` (2026-11-07).

## Decided
- Path: host sidecar RPC on dummy-mjolnir
- Install rides `just deploy`
- Occupancy: IRON Lab flock (spike `aie-occupancy-lock` — go; worker inherits flock fd)

## Feeds change
Unit + locator + admit socket + pending table + flock. HTTP
shape stays `add-aie-guest-offer`.
