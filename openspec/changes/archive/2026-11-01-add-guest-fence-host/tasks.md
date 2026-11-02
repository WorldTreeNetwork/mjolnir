# Tasks

- [x] Host identity, instance handle, and generation come from the authenticated channel
- [x] `classify` covers every retained admission, including missing keys, and an uncertain row stops adoption
- [x] `begin_adoption` retry returns the same grant, and a copied grant does not elect a new owner
- [x] `commit` records host acceptance before the guest write, on the transfer and revocation boundary
- [x] Lost contact drops the lease, and already admitted rows are not resent
- [x] Transfer revokes the old grant. Restore or clone advances the generation and drops the old grants
- [x] Receipts carry no secrets and are not exactly-once proof

## Advise amendments — 2026-10-31

- [x] R1: Specify pending/confirmed adoption, idempotent confirm, same-instance retries across fresh valid classifications, and lost-reply scenarios; align identity/generation results with the guest trait
- [x] R2: Specify classification history/instance binding, stale coverage checks at use, and unknown-row/generation-mismatch rejection scenarios
- [x] R3: Specify authority for Adopt/Lease/Admit/Reconcile, separately authorized reconciliation of existing keys, effect-contract policy, and negative scenarios
- [x] R4: Specify durable acceptance, retained history and generation recovery, plus restart/lost-reply/transfer race tests and the channel spike's ordering oracle
- [x] Tests cover lost begin, failure before confirm, and the full lost-confirm recovery; an undesignated instance; two successive owner claims against a captured older classification; foreign classification and wrong receipt generation; fresh Admit of an unknown key and unknown-key Reconcile rejection; crash before commit returns; lost acceptance response; transfer while a guest write stalls; restart that keeps an accepted key
- [x] Fresh advise after preparation: review the amended contract against reviews/2026-10-31-advise.md; keep the independent fence-channel go-or-skip gate

## Re-advise amendments — 2026-10-31

- [x] R1 follow-up: preserve pending or confirmed state across the full adoption retry, distinguish commit(Adopt) from grant issuance, and require host-designated replacement; add failure-before-confirm and undesignated-instance scenarios (reviews/2026-10-31-advise-2.md)
- [x] R2 follow-up: specify atomic advancement of the accepting owner's coverage while other classifications become stale; cover successive claims, foreign classifications, and wrong receipt generations
- [x] R3 follow-up: scope unknown-key refusal to reconciliation/classification, explicitly permit a valid fresh Admit, and cover unknown-key Reconcile rejection with exact grant binding
- [x] R4 follow-up: require durable acceptance before releasing the guest write and durable ownership transitions before exposing results; specify crash/lost-response/transfer-race tests and the stalled-or-disconnected guest ordering oracle for fence-channel

## Third advise amendments — 2026-10-31

- [x] R2 classification identity: distinguish a separately issued stale classification from a copy of the active classification ID; cover C0/C1 for the same instance, where accepting with C1 advances C1 but leaves C0 stale (reviews/2026-10-31-advise-3.md)
- [x] R2 receipt generation: compare each receipt with its retained admission's generation, separately from the current grant; cover valid historical/mixed-generation receipts and rejection of a receipt that disagrees with its own admission
- [x] R3 conflict scenario: scope submitted-digest conflicts to Admit and mismatching receipts at classify; express Reconcile checks using its actual scope/key payload, separate authorization, and preservation of the retained digest

## Out of scope

- Implementing the channel before `fence-channel` is `go` or skipped
- The api-proxy dialer and `POST /v1/execute`
