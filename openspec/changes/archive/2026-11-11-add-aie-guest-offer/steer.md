# steer add-aie-guest-offer

Inherited from `add-aie-compute` / `mjolnir-io3b` (2026-11-07).

## Decided
- Principal: Mjolnir VM being is the offerer
- Easy client: native catalog HTTP on `aie_url` + `mj compute`
  share/run (pinned at named activate 2026-11-11; parent steer
  had left OpenAI-compat vs IRON HTTP skipped). v1 job is a
  host-catalog design id, so chat-completions is not the
  execute shape. Path is `POST {aie_url}/v1/execute`.

## Feeds change
`mj compute` + `POST {aie_url}/v1/execute` + pending_id retry.
Mint copies incarnation onto the biscuit right. Third identity
is 403.
