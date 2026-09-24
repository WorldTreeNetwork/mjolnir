# Tasks

- [ ] Consume `identikey-auth` Challenge/Response as-is (`aud` = pinned edge XID)
- [ ] Specify the second signed authorization object (session public key, operation, channel)
- [ ] Keep identikey-core off the verify path
- [ ] Vectors: success, replay, expiry, wrong edge, wrong audience, altered request, holder-key substitution, transport replay
- [x] Advise — astra-arch-review, other-family reader for Grok; accepted in reviews/2026-09-24-advise-5.md (Fable infra-red).

## Owed from Astra architecture review — 2026-09-24

- [x] R1: Pin the second object's signing/verification semantics, challenge association, operation/resource limits, and same-holder managed-signing/consent handoff; reference session-key possession enforcement (reviews/2026-09-24-advise.md).
- [x] R2: Define authenticated edge/channel inputs and adapter comparison rules; specify rejection for replay to another same-transport connection and a wrong peer advertising the correct audience.
- [x] R3: Reconcile atomic nonce consumption and issuance with identikey-auth::verify_response consuming before return; specify concurrency/failure/restart outcomes and independent acceptance scenarios for all promised vectors.
- [x] Fresh advise after preparation — accepted revised contract in reviews/2026-09-24-advise-5.md.
- [x] Fresh independent advise after R1–R3 contract amendments — reviews/2026-09-24-advise-5.md; separate activation already recorded as ACTIVE BUILD.

## Owed from Astra architecture re-review — 2026-09-24

- [x] R4: Specify authenticated channel-value provenance and client/verifier comparison for each supported adapter, including the HTTPS gateway termination boundary; isolate same-transport replay with an unconsumed proof and a same-connection success control (reviews/2026-09-24-advise-2.md). Reopened by reviews/2026-09-24-advise-3.md: Decision 7 still omits authenticated shared-value delivery/comparison across termination, and the delta retains the completed-exchange replay scenario. Still open after pass 4 (reviews/2026-09-24-advise-4.md): specify the trusted external-connection handoff/comparison and an explicit N2 rejection → N1 success → N1 replay control; companion-id delivery and unconsumed-proof setup are now resolved. Amended after advise-4: gateway is channel authority; trusted hop injects conn_id+origin SPKI; verifier compares independently of the bind; N2 reject → N1 success → N1 replay is the normative control; plain HTTP deferred.
- [x] R5: Reconcile atomic nonce/issuance commit with invalid-bind, pre-commit failure, post-commit response loss/crash, and retry outcomes; add independent success/concurrency/recovery scenarios consistent with the chosen state contract (reviews/2026-09-24-advise-2.md). Reopened by reviews/2026-09-24-advise-3.md: reconcile Decision 6 and the normative delta with Decision 7, remove invalid-bind consumption, and add the missing combined success/concurrency/recovery scenarios. Still open after pass 4 (reviews/2026-09-24-advise-4.md): invalid-bind consumption is fixed; reconcile remaining consumed-without-issue prose and normative recovery rules, and add combined-success/concurrency/pre-commit/post-commit recovery scenarios. Amended after advise-4: consumed-without-issue removed; issued vs delivered; combined success, policy denial, pre-commit, concurrency, and post-commit loss scenarios added.
