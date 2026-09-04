# Tasks

Architecture artifacts for `add-lan-file-server`. Guest Recrypt
HTTP, LAN publish, and `meshd` are later landings after advise
accept. Grok authored; advise reader must not be Grok (ADR-005).

- [x] Steer decide-for-me 2026-09-04 (`mjolnir-h2fp.2`)
- [x] Write `design.md` (this change)
- [x] Write `steer.md` (this change)
- [x] Delta `specs/lan-files/spec.md` (ADDED)
- [x] Advise accept from a non-Grok reader with `READER:` banner
      (fable-5.1-arch-review, `reviews/2026-09-04-reread2-advise.md`)
- [x] Send-back 2026-09-04: pin fingerprint join — identikey-auth §5
      (`Blake3(dcbor(PublicKey))`) vs recrypt-storage-auth
      `granted_to` (`Blake3(raw Ed25519)`). Spec scenario "Cap
      permits read" must not treat them as one `f`. Mapping or one
      namespace, explicit. (`reviews/2026-09-04-advise.md`)
- [x] Send-back 2026-09-04: unmodified `recrypt-server` does not
      satisfy this share (`GET /files/{hash}` public; auth is not
      identikey-auth; storage is memory|local not blob-door;
      persistence default memory). Design "may run recrypt-server"
      must not license a drop-in. Name the four guest-HTTP deltas
      or a custom guest. (`reviews/2026-09-04-advise.md`)
- [x] Send-back 2026-09-04 (fable): publish targets are link state,
      not host facts. Observed: Ethernet DOWN, wifi `192.168.0.19`
      on a home AP, no `fd01:d28c:7e4a` address or route. Pin in
      `design.md`: publish binds by interface, never falls back to
      `0.0.0.0` / `::` / the GUA when the address is absent; name
      the ULA address (stable-privacy or `ipv6.token`), not the
      /48 prefix. Spec gains an "Ethernet unplugged" scenario
      mirroring the door's "Dummy address missing".
      (`reviews/2026-09-04-fable-advise.md`)
- [x] Send-back 2026-09-04 (fable): `aud` is one fixed service id
      across LAN v4, ULA, and `.mesh` name; never derived from
      `Host`, bound address, or port (identikey-auth §`aud` :98,
      :170). One sentence in `design.md`; spec scenario "Claimant
      holds the key" gains the path-independence clause.
      (`reviews/2026-09-04-fable-advise.md`)
- [x] Send-back 2026-09-04 (fable reread): cap gate has no root of
      trust — spec "Cap permits read" accepts any Capability for `h`
      granted to `g`, so a claimant self-issues one and reads any
      hash. Pin in `design.md`: put is identikey-auth gated and
      records `ownership(h) = g_putter` (`OwnershipStore::register`,
      first putter wins); GET requires the cap/chain root issuer to
      equal `ownership(h)`; issuer keys learned from `Verified` at
      auth time keyed by `g`. Spec gains "AND root issuer is the
      recorded owner" plus scenario "Cap issued by non-owner" →
      refused. (`reviews/2026-09-04-reread-advise.md`)
- [x] After accept: pointer in `docs/architecture.md` (do not delete
      prior sidecar text)

Handoffs (not checkboxes):

- Local Elixir upgrade — `mjolnir-h2fp.1` (brief/act)
- Recrypt guest + LAN proxy implementation — `mjolnir-h2fp.3`
- Mesh `meshd publish` — `mjolnir-h2fp.4`
- `add-iroh-blobs` — ADR 0003 remaining
- Biscuit agency — `update-identikey-capability`
