# Tasks

- [ ] Draft ADR `0012-direct-edge-auth` (trust pin, key split, no authlocal, discovery ≠ trust)
- [ ] Persist stable identity + operational keys under `/var/lib/mjolnir/auth` (`0600`, not `btrfs_root`)
- [ ] Ordinary sessions use operational keys only; stable key not required online
- [ ] Rotation overlap: unexpired capabilities remain valid across an op-key rotation
- [ ] Offline verifier can check the full stable-XID → op-key chain
- [ ] Compromise/recovery written (op-key rotate vs restore auth dir)
- [x] Advise — astra-arch-review, other-family reader of Grok; accepted in `reviews/2026-09-24-advise-5.md` (Fable infrastructure unavailable).

## Owed from advise 2026-09-24 — astra-arch-review

Review: `reviews/2026-09-24-advise.md` (send-back). Amend this node's design and delta before fresh advise; these do not authorize implementation or change the PENDING banner.

- [x] R1: Define the stable-XID/public-key/delegation verification contract, purposes, validity, key IDs, delegation limits, and negative verification scenarios.
- [x] R2: Define provisioning, root-offline restart, startup generation versus authorization, rotation, and fail-closed behavior for missing/corrupt key state.
- [x] R3: Define bounded overlap/retirement and offline revocation freshness, including repeated rotations and a stale verifier receiving newly forged K1 capabilities; numeric defaults may remain deferred.
- [x] R4: Define safe private-file creation/path enforcement, crash-consistent activation, backup/restore, and root loss/compromise handling, with failure scenarios.
- [x] Fresh advise after preparation — astra-arch-review, `reviews/2026-09-24-advise-5.md`; reviewed contract identified there by SHA-256.
- [x] Fresh independent advise after R1–R4 are reconciled; astra-arch-review accepted the reconciled Decisions 1–9 and edge-auth delta in `reviews/2026-09-24-advise-5.md` (contract hashes recorded there).

## Owed from second advise 2026-09-24 — astra-arch-review

Review: `reviews/2026-09-24-advise-2.md` (send-back). The earlier checked R1–R4 entries record the first amendment pass; the residual contracts below remain owed. PENDING and the fresh-advise gates remain unchanged.

- [x] R1b: Define or precisely reference XID-to-identity-public-key verification and the signed delegation representation/domain; add attacker-root-with-victim-XID, wrong-edge, and validity-boundary scenarios.
- [x] R3b: Define authenticated supersession targets, effect, durable precedence over replay, and expiry semantics; define retained public evidence across repeated rotations and reconcile capability validity with delegation expiry; add negative and repeated-rotation scenarios.
- [x] R4b: Define stale-backup reconciliation inputs and fail-closed recovery when authoritative state is unavailable; distinguish root compromise from root loss; add stale-restore, interrupted-activation, and private-permission failure scenarios.


## Owed from third advise 2026-09-24 — astra-arch-review

Review: `reviews/2026-09-24-advise-3.md` (send-back). Decision 9 addresses parts of advise-2, but the following residuals remain. Historical checked entries are preserved; both fresh-advise gates stay open. The proposal remains ACTIVE BUILD; this review does not flip its banner or authorize act.

- [x] R3c: Complete canonical signed grant/supersession representation, authenticated target, revocation timing/expiry and durable replay precedence; reconcile retained public evidence with repeated graceful overlap. Update the delta with target-tamper, late-receipt, restart/replay, and K1→K2→K3 scenarios.
- [x] R4c: Treat a stale prefix as reconciliation input only, never directly activatable authority; identify required authenticated recovery evidence/operator procedure and fail-closed behavior when unavailable. Preserve observed revocations across restore/interrupted activation, reconcile backup guidance, and add stale-prefix, missing-authority, interrupted-activation, and permission-at-open scenarios to the delta.
- [x] R4d: Require a new identity/pin after stable-private compromise unless an independently authorized recovery mechanism is explicitly defined/referenced; distinguish operational compromise and root loss, and add a stolen-root/fresh-attacker-delegation scenario to the delta.

## Owed from fourth advise 2026-09-24 — astra-arch-review

Review: `reviews/2026-09-24-advise-4.md` (send-back). Stable-private compromise/new-pin handling resolves R4d. R3c/R4c still need the following contract and delta amendments; historical checked entries are preserved. Both fresh-advise gates remain open and the proposal remains ACTIVE BUILD.

- [x] R4e: Define current recovery authorization and the declared-restore reconciliation procedure, evidence retained outside the restored bundle, bundle-hash coverage, log ordering/merge if supported, and fail-closed behavior when current evidence is unavailable. An old valid attestation must not override learned revocations. Reconcile Decision 7 backup guidance; add old-attestation/stale-bundle replay, missing-current-authority, and interrupted-activation-after-revocation scenarios. Amended after advise-4: fresh restore ceremony attests reconciled output (`auth-restore` + restore_id + observed_revocations_hash); old A1+B1 cannot revive K1; missing current evidence fail-closed; interrupted activation keeps learned revocation.
- [x] R3d: Reconcile supersession descriptions into one canonical signed contract with explicit effective-time versus expiry semantics, late receipt, durable negative-evidence retention, and separately delegated successor authority. Carry it into the delta with target-tamper, late-receipt, restart/replay, and K1→K2→K3 graceful-overlap scenarios; include the outstanding permission-at-open failure contract/scenario from R4c. Amended after advise-4: sole encoding is `op-supersede`; `exp_now` is effective revocation time; late receipt and restart/replay honor it; `next_kid` names a separately delegated successor; permission-at-open fail-closed; K1→K2→K3 overlap scenario added.
