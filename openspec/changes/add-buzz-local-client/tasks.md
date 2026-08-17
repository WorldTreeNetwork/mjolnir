# Tasks

Work this change owes (architecture write only):

- [x] Proposal + journey on existing surfaces
- [x] `design.md` ADR (mailbox, admit, sidecar, images, relay)
- [x] `docs/decisions/0002-buzz-local-client-fabric.md` index entry
- [x] Pointer from `docs/architecture.md` naming this change-id
- [x] Deltas under `specs/buzz-local-client/spec.md`
- [x] Bead note on `mjolnir-e70` pointing at this change
- [x] Independent architecture read (Fable 5 + GPT-5.6 Sol, 2026-08-16)
- [ ] Amend spec: enforcement is `deliver_message/3` before queue, all callers
- [ ] Amend spec: dormant vs `:stopped` vs `:never`; mention-wake v1 posture
- [ ] Amend spec: protocol (identikey-protocol) vs host lifecycle policy; fail-closed

Handoffs (not checkboxes):

- Review write-up: `reviews/2026-08-16-advise.md`
- Combined verdict: amend deltas before `act` on mailbox / admit / deploy

- `change add-identikey-admit` in `identikey-protocol` after the read
- `act` on this change is **not** deploy — later nodes implement
- Fold only after a later change has made these SHALLs true in code
