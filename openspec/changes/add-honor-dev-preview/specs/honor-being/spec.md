## ADDED Requirements

### Requirement: grok and Vite share tmux main on the ticket URL

A hosted being SHALL have grok on PATH in tmux session `main` and
SHALL serve the storefront with Vite bound on `0.0.0.0` so
`https://<ticket>.vm.worldtree.network` loads it. Frontend env SHALL
point at `https://api.hypersigil.world`. `XAI_API_KEY` SHALL live
only in guest tmpfs.

#### Scenario: Preview talks to prod API

- GIVEN Vite is up and the ticket URL loads
- WHEN the storefront fetches products
- THEN requests go to `https://api.hypersigil.world`

#### Scenario: grok key is not in the snapshot

- GIVEN a `hosted-<xid>` snapshot
- WHEN that snapshot is mounted on the host
- THEN it does not contain `XAI_API_KEY`
