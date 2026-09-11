# Tasks

Activated 2026-09-10. Relay / NIP-OA is **not** this change
(`add-buzz-relay`, hive live at `wss://buzz.identikey.me`).

- [x] Protocol facade: Nostr (later Matrix) → OTP → conformant Nostr
      at a Buzz body. Host is not a second event log.
- [x] Wake producer is that ingress (not guest, Reconcile, or a
      desktop-only side channel)
- [x] Signed attestation + lifecycle epoch field as a portable
      crate in `identikey-protocol` (Apache-2.0 or BSD-2-Clause-Patent;
      no `identikey-core`). `Mjolnir.Admit` stays the v1 evaluator
      (no NIF this slice).

Handoffs (not checkboxes):

- B0 community relay — `add-buzz-relay` / `mjolnir-gti` (live)
- nsec SecretStore inject — folded `mjolnir-1pe`
- Catalog images — ADR 0009 (`ubuntu-24.04`, `ci-ubuntu-24.04`,
  `buzz-agent`). Do not add `@base/dev`.
- Restore hive — `docs/runbooks/buzz-relay-restore.md`
