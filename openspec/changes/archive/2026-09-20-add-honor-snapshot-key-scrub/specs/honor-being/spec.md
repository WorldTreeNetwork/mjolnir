## ADDED Requirements

### Requirement: Hosted snapshot does not persist XAI_API_KEY

A hosted-being snapshot SHALL NOT contain `XAI_API_KEY` in the
storefront `.env`, grok's config directory, or shell history.
The key SHALL remain injectable into guest tmpfs (`/run/mjolnir/`)
after boot from that snapshot.

#### Scenario: Snapshot tree is clean

- GIVEN a hosted being that has run grok
- WHEN `mj snapshot create` writes `hosted-<xid>`
- THEN the snapshot tree does not contain `XAI_API_KEY`
- AND a later spawn from that snapshot can still receive the key
  in `/run/mjolnir/` tmpfs
