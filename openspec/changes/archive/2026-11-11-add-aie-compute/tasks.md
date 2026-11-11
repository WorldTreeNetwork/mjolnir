# Tasks

- [x] ADR 0015 in `docs/decisions/0015-aie-compute-sidecar.md` matching design.md one-screen
- [x] Amend ADR 0015 one-screen and scenario list to the Fable pins (contract text; fresh advise still owed)
- [x] Point `docs/guide/host-sidecars.md` catalog at this change (locator row after sidecar lands; this change may add a "not built" footnote)
- [x] Architecture tests: the scenarios in `specs/aie-compute/spec.md` are named so implement nodes can close them; this change does not ship the sidecar
- [x] Pin R5/R6 from `reviews/2026-11-11-advise-2.md` into design, delta, and ADR 0015 (contract text; fresh advise still owed)
- [x] Pin R6a from `reviews/2026-11-11-advise-3.md` (live admit on occupancy `attempt_id` vs status-only cached dispatched)
- [x] Fresh advise after preparation

Fresh accepting reader: `astra-arch-review`, review `reviews/2026-11-11-advise-4.md`. The review records SHA-256 contract hashes for this R5/R6/R6a revision; the occupancy spike and child activation gates remain unchanged.

## Owed by advise — astra-arch-review

Review: `reviews/2026-11-07-advise.md` (send-back), tracked under `mjolnir-io3b.2`. These are contract amendments; implementation remains with the named child nodes.

- [x] R1: Pin execute holder proof, request/verifier binding, replay handling, and verifier-only fact provenance; add stolen-token, replay, tampered-job, and forged-fact refusal scenarios. (design Decision 4; spec Execute is a holder-checked Biscuit)
- [x] R2: Pin canonical offer scope, owner-to-being/VM/capacity authority, and trusted mint issuer; add cross-keyspace collision, unrelated-VM, and untrusted-issuer refusal scenarios. (design Decision 5; spec Capacity is a signed keyspace claim)
- [x] R3: Pin offer withdrawal/replacement, same-key guild evidence, membership freshness, and queued/running admission boundaries; add revocation, policy-change, and key-mismatch scenarios. (design Decision 6; spec Guild-scoped offers inject membership)
- [x] R4: Pin the shared IRON lock protocol and worker/quiescence lifetime through timeout, cancellation, and restart; assign the unproved integration scenarios to add-aie-host-sidecar. (design Decision 7 + `aie-occupancy-lock` go; spec Sidecar serializes NPU occupancy)
- [x] Fresh advise after these contract amendments; independent reader accepted the reconciled contract in `reviews/2026-11-11-advise.md` (astra-arch-review).

## Owed by fresh advise — astra-arch-review (2026-11-10)

Review: `reviews/2026-11-10-advise.md` (send-back), continuing R3 under `mjolnir-io3b.2`. R1, R2, and R4 are satisfied at architecture rigor; these amendments remain with the contract author and named implementation nodes.

- [x] R3a: Pin an issuer-authenticated offer-incarnation binding or permanently retired resource-ID rule shared by offer publication, mint, and admission. Specify replacement, tombstone/recreation, and restart behavior; add unchanged-policy replacement, newly minted grant success, old personal token held by a current guild member, and no-resurrection scenarios. (design Decisions 4–5: incarnation = Blake3 of signed leaf; spec Capacity + Execute)
- [x] R3b: Reconcile lookup TTL with membership removal at admission. Choose authoritative admission revalidation or bounded delayed revocation; define freshness-bound ownership and its time origin, align design and delta, and add removal-before-expiry, removal-after-bound, and lookup-failure scenarios. (design Decision 6: admission lookup is authoritative; spec Guild-scoped offers)

## Owed by consult — fable-5.2 (2026-11-11)

Consult: `groups/add-aie-compute/results/fable-5.2-consult.md` (caution). Contract pins; implementation stays with named children. Historical Astra accept does not cover this revision.

- [x] F1: BEAM admits on the operator socket; sidecar enforces; nonce consume at enqueue only; max queue age. (design Decision 4)
- [x] F2: Operator allowlist of offering VM ids at publish, mint, and admission. (design Decision 5)
- [x] F3: Leaf sequence + tombstone floor; re-put of retired bytes refused; v1 whole-offer revocation. (design Decision 5)
- [x] F4: v1 job = host-catalog design id + bounded input; dedicated sidecar user; wall time on the leaf. (design Decision 8)
- [x] F5: try-lock, revalidate under deadline, then load or release; no membership lookup while waiting on the flock. (design Decisions 6–7)
- [x] F6: Holder is the consumer VM; guild uses member-signed delegation; membership is verifier inject, not Datalog mint. (design Decision 6)
- [x] F7: Locators as a map; audience is mint-root fingerprint. (design Decision 3)

## Owed by fresh advise — astra-arch-review (2026-11-11, pass 2)

Review: `reviews/2026-11-11-advise-2.md` (send-back), tracked under `mjolnir-io3b.2`. Contract hashes and the independent take are recorded in that review. Implementation remains with the named children; `Fresh advise after preparation` remains open.

- [x] R5: Reconcile the dedicated non-root sidecar with the root-only, full-authority operator socket. Pin an authenticated admission-scoped BEAM channel, permissions/credential ownership and restart behavior; reconcile design, delta, and ADR and assign the child owner. Add non-root admission success, unrelated-user refusal, denial of general operator VM/snapshot routes to the sidecar identity, and listener-restart boundary scenarios. (design Decision 4 + 8; spec Sidecar admits on a scoped BEAM channel; child `add-aie-host-sidecar`)
- [x] R6: Pin the authenticated enqueue-to-dispatch lifecycle shared by add-aie-host-sidecar and add-aie-guest-offer: pending-state owner/reference, immutable verified-frame and enqueue-time binding, atomic at-most-one dispatch, duplicate/lost-reply handling, cancellation/expiry, and BEAM/sidecar restart invalidation or recovery. Add no-enqueue, changed-reference/job, concurrent duplicate admission, lost-reply retry, restart-pending, and expired/cancelled-reference scenarios; retries must not reset queue age. (design Decision 4; spec Execute is a holder-checked Biscuit)

## Owed by fresh advise — astra-arch-review (2026-11-11, pass 3)

Review: `reviews/2026-11-11-advise-3.md` (send-back), continuing R6 under `mjolnir-io3b.2`. R5 and the pending-table/frame/restart portions of R6 are satisfied. Contract hashes are recorded in the review; `Fresh advise after preparation` remains open.

- [x] R6a: Distinguish cached admission status from permission for the first NPU load; pin its occupancy-attempt/deadline lifetime and sidecar duplicate suppression. Reconcile already-dispatched refusal with lost-reply outcome replay, including deadline expiry, lock release, cancellation/restart, and late replies. Add lost-reply then lock-release/revocation, late-success-after-abandonment, and duplicate-success-at-most-one-load scenarios. A terminal fail-closed uncertain admission with status-only retry is sufficient; no durable queue or exactly-once completion is required. Reconcile design, delta, and ADR; shared owners remain add-aie-host-sidecar and add-aie-guest-offer. (design Decision 4 + 6: live admit on `attempt_id`; spec Execute)

## Out of scope

- Sidecar unit / bind / INPUT / `just deploy` install — `add-aie-host-sidecar`
- `mj` verb and HTTP route shape — `add-aie-guest-offer`
- SecretStore offer leaf — `add-aie-keyspace-claims`
- `member(ks, pk)` inject — `add-guild-compute-holder`
- VFIO, virtio-accel, `mjolnir-03x`
- Fold of unbuilt SHALLs into living `openspec/specs/aie-compute/` before implement nodes land
- Guest-authored xclbin
