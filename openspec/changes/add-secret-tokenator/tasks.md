# Tasks

Architecture artifacts for `add-secret-tokenator`. HTTP/NIF/CLI are
later landings after advise accept. Grok authored; advise reader
must not be Grok (ADR-005). Fable 5 is the cross-family reader.
Sol is not subscribed.

- [x] Write `design.md` (decisions)
- [x] Write ADR index `docs/decisions/0008-secret-tokenator.md` as Proposed
- [x] Delta `specs/secret-tokenator/spec.md` (ADDED)
- [x] Advise accept-with-nits (Fable) —
      `reviews/2026-08-26-fable-advise.md`. Nits go to act
      nodes (Gordian verify_envelope, Blake3, Auth branch
      order, challenge presents Biscuit, salted elision).
      Cross-family accept (ADR-005).
- [x] Send-back 2026-08-26: Auth plug fourth branch, not skip_auth
- [x] Send-back 2026-08-26: holder fingerprint encoding (protocol)
- [x] Send-back 2026-08-26: reused nonce fails closed
- [x] Send-back 2026-08-26: vault is owner envelope, not host-global
      opaque; secret_id path-safe
- [x] Send-back 2026-08-26: copy-out to RAM/tmpfs, not virtio-fs;
      thin proxy named as more-secure pattern
- [ ] After accept: pointer in `docs/architecture.md` (do not delete
      prior ADR text)
- [ ] After accept: fold deltas into `openspec/specs/secret-tokenator/`
      only when the first implementing act has landed, or fold
      architecture-only SHALLs that are already true of the design
      (do not import unimplemented HTTP into living specs —
      learning 2026-08-16)

Handoffs (not checkboxes):

- `add-biscuit-runtime` (`mjolnir-axsb.1.3`) — NIF / authority key
- `add-tokenator-redeem` (`mjolnir-axsb.1.4`) — challenge + POST
- `add-capability-mint` (`mjolnir-axsb.1.5`) — deposit + mint
- `add-capability-hop` (`mjolnir-axsb.1.6`) — signed block per hop
- Papyrus UI — `mjolnir-axsb.2`
- Single-use / N-use redeem_count — Decision 5, later
- GitHub proxy that never copies the PAT — Decision 4, later
