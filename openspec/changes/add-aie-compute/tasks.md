# Tasks

- [x] ADR 0015 in `docs/decisions/0015-aie-compute-sidecar.md` matching design.md one-screen
- [x] Point `docs/guide/host-sidecars.md` catalog at this change (locator row after sidecar lands; this change may add a "not built" footnote)
- [x] Architecture tests: the scenarios in `specs/aie-compute/spec.md` are named so implement nodes can close them; this change does not ship the sidecar

## Owed by advise — astra-arch-review

Review: `reviews/2026-11-07-advise.md` (send-back), tracked under `mjolnir-io3b.2`. These are contract amendments; implementation remains with the named child nodes.

- [x] R1: Pin execute holder proof, request/verifier binding, replay handling, and verifier-only fact provenance; add stolen-token, replay, tampered-job, and forged-fact refusal scenarios. (design Decision 4; spec Execute is a holder-checked Biscuit)
- [x] R2: Pin canonical offer scope, owner-to-being/VM/capacity authority, and trusted mint issuer; add cross-keyspace collision, unrelated-VM, and untrusted-issuer refusal scenarios. (design Decision 5; spec Capacity is a signed keyspace claim)
- [x] R3: Pin offer withdrawal/replacement, same-key guild evidence, membership freshness, and queued/running admission boundaries; add revocation, policy-change, and key-mismatch scenarios. (design Decision 6; spec Guild-scoped offers inject membership)
- [x] R4: Pin the shared IRON lock protocol and worker/quiescence lifetime through timeout, cancellation, and restart; assign the unproved integration scenarios to add-aie-host-sidecar. (design Decision 7 + unverified `aie-occupancy-lock`; spec Sidecar serializes NPU occupancy)
- [x] Fresh advise after these contract amendments; independent reader accepted the reconciled contract in `reviews/2026-11-11-advise.md` (astra-arch-review).

## Owed by fresh advise — astra-arch-review (2026-11-10)

Review: `reviews/2026-11-10-advise.md` (send-back), continuing R3 under `mjolnir-io3b.2`. R1, R2, and R4 are satisfied at architecture rigor; these amendments remain with the contract author and named implementation nodes.

- [x] R3a: Pin an issuer-authenticated offer-incarnation binding or permanently retired resource-ID rule shared by offer publication, mint, and admission. Specify replacement, tombstone/recreation, and restart behavior; add unchanged-policy replacement, newly minted grant success, old personal token held by a current guild member, and no-resurrection scenarios. (design Decisions 4–5: incarnation = Blake3 of signed leaf; spec Capacity + Execute)
- [x] R3b: Reconcile lookup TTL with membership removal at admission. Choose authoritative admission revalidation or bounded delayed revocation; define freshness-bound ownership and its time origin, align design and delta, and add removal-before-expiry, removal-after-bound, and lookup-failure scenarios. (design Decision 6: admission lookup is authoritative; spec Guild-scoped offers)

## Out of scope

- Sidecar unit / bind / INPUT / `just deploy` install — `add-aie-host-sidecar`
- `mj` verb and HTTP route shape — `add-aie-guest-offer`
- SecretStore offer leaf — `add-aie-keyspace-claims`
- `member(ks, pk)` inject — `add-guild-compute-holder`
- VFIO, virtio-accel, `mjolnir-03x`
- Fold of unbuilt SHALLs into living `openspec/specs/aie-compute/` before implement nodes land
