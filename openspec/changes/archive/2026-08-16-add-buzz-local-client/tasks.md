# Tasks

Work this change owes (architecture write only):

- [x] Proposal + journey on existing surfaces
- [x] `design.md` ADR (mailbox, admit, sidecar, images, relay)
- [x] `docs/decisions/0002-buzz-local-client-fabric.md` index entry
- [x] Pointer from `docs/architecture.md` naming this change-id
- [x] Deltas under `specs/buzz-local-client/spec.md`
- [x] Bead note on `mjolnir-e70` pointing at this change
- [x] Independent architecture read (Fable 5 + GPT-5.6 Sol, 2026-08-16)
- [x] Amend spec: proxies attest; trusted deliver checks stamp; before queue
- [x] Amend spec: Nostr/Matrix facade; wake producer; dormant vs `:stopped` vs `:never`
- [x] Amend spec: protocol vs host policy; fail-closed; sidecar is schemas
- [x] design.md Decision 4: protocol crate is wire+validators, not the host facade
- [x] design.md Decision 5: sidecar grows schemas, not named databases
- [x] Spec: lifecycle epoch is not StateStore persist generation

Handoffs (not checkboxes):

- Review write-up: `reviews/2026-08-16-advise.md`
- Architecture write (including 2026-08-16 amend) is complete
- Fold blocked until later act nodes make the SHALLs true
- Pubkey distribution for envelope verify → `nod-identikey-admit`
- `change add-identikey-admit` in `identikey-protocol`
- `act` on this change is **not** deploy

- `change add-identikey-admit` in `identikey-protocol` after the read
- `act` on this change is **not** deploy — later nodes implement
- Fold only after a later change has made these SHALLs true in code
