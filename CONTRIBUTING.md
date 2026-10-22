# Contributing to Mjolnir

Copyright is held by **World Tree Network Foundation** (`duke@worldtree.io`).
IdentiKey as a *product* name (Sites, identity) is unrelated to the former
corporate owner.

## Licenses (inbound = outbound)

This repository is split on purpose. See [NOTICE](NOTICE) and
[docs/philosophy/licensing-and-components.md](docs/philosophy/licensing-and-components.md).

| You are changing | License your contribution is accepted under |
|---|---|
| `native/mjolnir_client`, `native/mjolnir_api`, `native/mjolnir_protocol` | MIT |
| Everything else (Elixir orchestrator, guest agent, gateway, blob door, scripts, docs that describe the host) | AGPL-3.0-or-later |

Do not move code from an AGPL crate into an MIT crate. The CLI must not
gain an AGPL dependency.

## Contributor License Agreement (required)

Mjolnir is **split-licensed** (AGPL host, MIT CLI) and the host is
**dual-licensed** (AGPL + a commercial exception). That only works if
the Project can license every contribution under both. **Before your
first pull request is merged, you must agree to the
[Contributor License Agreement](CLA.md).**

- **Individuals:** the CLA bot ([CLA Assistant](https://cla-assistant.io))
  will comment on your first PR. Signing once covers future work. If the
  bot is down, add yourself to
  [`contributors/individual.md`](contributors/individual.md) using the
  statement in CLA.md → *How to sign* → Option A.
- **Contributing on behalf of an employer:** have an authorized
  representative complete the Corporate CLA (CLA.md → Option B) by
  emailing **duke@worldtree.io**.

You keep the copyright — the CLA is a license, not an assignment.
Commercial terms for the host: [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md).

## Development

```bash
mix deps.get && mix test          # unit tests; no KVM
cd native && cargo test -p mjolnir-protocol -p mjolnir-api
```

VM integration tests need Linux + KVM + root. See [README](README.md)
and [docs/hardware-requirements.md](docs/hardware-requirements.md).

Issue tracking is **beads** (`bd ready`, `bd show`, `bd close`), not
GitHub issues.
