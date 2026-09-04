# Tasks

Architecture artifacts for `add-lan-file-server`. Guest Recrypt
HTTP, LAN publish, and `meshd` are later landings after advise
accept. Grok authored; advise reader must not be Grok (ADR-005).

- [x] Steer decide-for-me 2026-09-04 (`mjolnir-h2fp.2`)
- [x] Write `design.md` (this change)
- [x] Write `steer.md` (this change)
- [x] Delta `specs/lan-files/spec.md` (ADDED)
- [ ] Advise accept from a non-Grok reader with `READER:` banner
- [ ] Send-back 2026-09-04: pin fingerprint join — identikey-auth §5
      (`Blake3(dcbor(PublicKey))`) vs recrypt-storage-auth
      `granted_to` (`Blake3(raw Ed25519)`). Spec scenario "Cap
      permits read" must not treat them as one `f`. Mapping or one
      namespace, explicit. (`reviews/2026-09-04-advise.md`)
- [ ] Send-back 2026-09-04: unmodified `recrypt-server` does not
      satisfy this share (`GET /files/{hash}` public; auth is not
      identikey-auth; storage is memory|local not blob-door;
      persistence default memory). Design "may run recrypt-server"
      must not license a drop-in. Name the four guest-HTTP deltas
      or a custom guest. (`reviews/2026-09-04-advise.md`)
- [ ] After accept: pointer in `docs/architecture.md` (do not delete
      prior sidecar text)

Handoffs (not checkboxes):

- Local Elixir upgrade — `mjolnir-h2fp.1` (brief/act)
- Recrypt guest + LAN proxy implementation — `mjolnir-h2fp.3`
- Mesh `meshd publish` — `mjolnir-h2fp.4`
- `add-iroh-blobs` — ADR 0003 remaining
- Biscuit agency — `update-identikey-capability`
