# Tasks

Architecture artifacts for `add-secret-tokenator`. HTTP/NIF/CLI are
later landings after advise accept. Grok authored; advise reader
must not be Grok (ADR-005). Fable 5 is the cross-family reader.
Sol is not subscribed.

- [x] Write `design.md` (decisions)
- [x] Write ADR index `docs/decisions/0008-secret-tokenator.md` as Proposed
- [x] Delta `specs/secret-tokenator/spec.md` (ADDED)
- [x] Advise accept-with-nits (Fable) —
      `reviews/2026-08-26-fable-advise.md`. Cross-family
      accept (ADR-005).
- [x] Human amend 2026-08-26: Blake3 (not SHA-256 stub) for
      holder fp and commitments; Gordian envelopes deferred;
      salt mandatory on any public digest of a secret
- [x] Human 2026-08-26: tokenator stays in the BEAM (option A)
- [x] Send-back 2026-08-26: Auth plug fourth branch, not skip_auth
- [x] Send-back 2026-08-26: holder fingerprint encoding (protocol)
- [x] Send-back 2026-08-26: reused nonce fails closed
- [x] Send-back 2026-08-26: vault is owner envelope, not host-global
      opaque; secret_id path-safe
- [x] Send-back 2026-08-26: copy-out to RAM/tmpfs, not virtio-fs;
      thin proxy named as more-secure pattern
- [ ] Send-back 2026-09-04 (Fable, `reviews/2026-09-04-fable-advise.md`
      finding 1): vault root vs off-box backup. `secret_store_root`
      is under `@sites`, which `backup-sites-b2.sh` rclone-copies to
      B2 append-only (`hard_delete=false`). Decision 1 names the
      vault's on-disk root and picks: root outside `@sites` (escrow
      precedent, `config.exs:34-38`) or `--exclude 'keyspace/_opaque/**'`
      named as load-bearing. Spec SHALL + scenario: secret bytes are
      not copied off-host by Mjolnir's own backup jobs.
- [ ] Send-back 2026-09-04 (Fable, finding 2): `mj freeze` persists
      guest RAM (`@snapshots/<name>.mem`, vm-freeze spec), so
      "process memory or tmpfs" is a snapshot sink. Decision 4 names
      freeze and picks: quiesce hook drops redeemed secrets
      (`MemorySnapshot` `:quiesce_fun` seam, re-redeem after thaw), or
      `.mem` declared secret-bearing, or explicitly accepted with the
      Decision 5 revocation caveat. One scenario under "Copy-out is
      v1"; cross-ref `vm-freeze`.
- [ ] After accept: pointer in `docs/architecture.md` (do not delete
      prior ADR text)
- [ ] After accept: fold deltas into `openspec/specs/secret-tokenator/`
      only when the first implementing act has landed, or fold
      architecture-only SHALLs that are already true of the design
      (do not import unimplemented HTTP into living specs —
      learning 2026-08-16)

Handoffs (not checkboxes):

- `add-biscuit-runtime` (`mjolnir-axsb.1.3`) — NIF / authority
  key / **real Blake3** (do not call `Sites.Crypto.blake3_hash/1`
  while it is SHA-256). Sites keyspace fingerprint cutover is
  not this vault.
- `add-tokenator-redeem` (`mjolnir-axsb.1.4`) — challenge + POST
- `add-capability-mint` (`mjolnir-axsb.1.5`) — deposit + mint
- `add-capability-hop` (`mjolnir-axsb.1.6`) — signed block per hop
- Papyrus UI — `mjolnir-axsb.2`
- Single-use / N-use redeem_count — Decision 5, later
- GitHub proxy that never copies the PAT — Decision 4, later
