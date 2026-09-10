# Advise — update-identikey-capability (architecture, cross-family accept read)

> **ADVISE:** accept-with-nits

Reader: Fable 5. Cross-family accept reader per ADR-005 (Grok
authored; Grok's own 2026-08-26 review was send-back, so this is
the accept pass, not a same-family sole-accept).

Signed result: `permission: write` (reviews only), `disposition: task-green`.

Date: 2026-08-26. Scope: `proposal.md`, `design.md`, `tasks.md`,
`specs/identikey-capability/spec.md`, Grok review
`reviews/2026-08-26-advise.md`, living
`identikey-capability-v1.md` (§3.1–3.3),
`identikey-auth-challenge-v1.md` (§5), `lib/mjolnir/secret_store.ex`,
`lib/mjolnir/api/auth.ex`, `lib/mjolnir/sites/identikey.ex`,
`lib/mjolnir/sites/crypto.ex`, `docs/LEARNINGS.md`, sibling
`add-secret-tokenator`.

## Verdict

Accept, with nits that are fold/implementer notes, not spec-text
changes. All three of Grok's send-back findings are genuinely
closed in the deltas (verified line-by-line below, not taken from
the tasks.md checkboxes). The SHALLs as written are consistent
with `identikey-capability-v1.md` §3.2–3.3 and auth-challenge §5,
do not forbid rbac-design Phase 1, and encode Duke's 2026-08-26
vault call (elided Gordian envelope, digest-verifiable copy-out).
Safe to `act` the fold.

## Send-back closure check (the reason this read exists)

- **Grok finding 1 — holder SHALL was global.** Closed. The
  requirement now opens "A Biscuit that authorizes `redeem` of a
  foreign secret" (`specs/identikey-capability/spec.md:5-6`) and
  adds an explicit carve-out: "This requirement SHALL NOT apply to
  other agency profiles (VM exec, mailbox, snapshot)… A root
  VM-exec Biscuit without a holder check is not a violation"
  (`spec.md:16-18`). Phase 1 VM biscuits are no longer silently
  forbidden.
- **Grok finding 2 — hop SHALL contradicted Decision 4.** Closed.
  "v1 redeem SHALL succeed with zero hop blocks when the issuer
  bound the holder at mint" (`spec.md:53-54`) plus the
  issuer-bound scenario "missing hop blocks are not a failure"
  (`spec.md:64-69`). Spec and design Decision 4 (`design.md:87-88`)
  now say the same thing.
- **Grok finding 3 — "forwarding agent's key" was not
  biscuit-auth attenuation.** Closed. "v1 hop blocks are nextKey
  attenuation… That proves monotonicity, not Identikey
  attribution. Identikey-signed hops SHALL use Biscuit third-party
  blocks and are not v1" (`spec.md:59-62`), with a rejection
  scenario for Identikey-as-nextKey (`spec.md:78-85`). This
  matches the living protocol: "A P-256 enclave identity does not
  sign Biscuit blocks" (`identikey-capability-v1.md:92`).
- **Fingerprint encoding.** Closed. `holder(<fingerprint>)` where
  fingerprint is auth-challenge v1 §5 (`spec.md:7-9`); design adds
  "HTTP proof carries `{alg, key}`; the verifier computes `fp`…
  Do not stuff raw key bytes into Datalog" (`design.md:60-62`).
  §5 is Blake3 over the dCBOR self-describing key map
  (`identikey-auth-challenge-v1.md:142-149`), so the delta's
  reference is exact.

## Steelman against

**Scoping holder-binding to the secret-redemption profile
normalizes bearer tokens everywhere else.** Strongest version: the
spec now *formally declares* that a stolen VM-exec Biscuit working
verbatim "is not a violation of this spec" (`spec.md:16-18`).
Exec is side-effectful and at least as dangerous as a PAT; if
holder proof is the right idea, it should be the default with
explicit opt-outs, not an opt-in profile — otherwise the next
profile author inherits bearer-only as the blessed baseline.

Why it fails: VM-exec tokens ride channels that already carry a
first-factor (JWT / localhost at the Auth plug; guests get no
loopback bypass, `lib/mjolnir/api/auth.ex:139-143`), while redeem
is uniquely a copy-out of a long-lived foreign credential where
token theft is silent and catastrophic. Forcing a
challenge-signature round trip onto every exec would block
rbac-design Phase 1 for no modeled threat, and the profile
mechanism is monotone: adding a holder check to a future profile
is attenuation-shaped, removing one is not. The global SHALL was
exactly what Grok correctly sent back; the profile scope is the
amendment, not a loophole.

## One real tradeoff

**nextKey hops buy monotonicity, not custody.** Decision 4's title
says "hop provenance," but a v1 nextKey block proves only that
*someone holding the token bytes* narrowed them — it does not
identify A, B, or C (`design.md:90-95`, `spec.md:59-62`).
Question 4 of the Problem ("What is the provenance of
A → B → C → Z?") is therefore answered in v1 as "the chain proves
nothing was widened," with actual who-forwarded attribution
deferred to third-party blocks in `add-capability-hop`. That is
the right v1 cut — redeem is issuer-bound and holder-checked, so
custody attribution is forensic nice-to-have, not a security
control — but readers of the fold should not believe v1 gives them
an audit trail of intermediaries. It does not.

## Findings (nits — none block accept)

1. **Two fingerprint conventions will coexist on the Mjolnir
   host; the fold should not let implementers conflate them.**
   The holder fingerprint is Blake3 over the dCBOR `{alg, key}`
   map (`identikey-auth-challenge-v1.md:142-149`). Mjolnir's
   existing `identikey_fp` — the SecretStore keyspace key — is
   `IdentiKey.fingerprint/1`, base58 of a hash of the *raw*
   Ed25519 public bytes (`lib/mjolnir/sites/identikey.ex:75-77`),
   and that hash is today a SHA-256 stub, not Blake3
   (`lib/mjolnir/sites/crypto.ex:24-29`). Auth-challenge §5
   explicitly makes these distinct namespaces by construction
   (`identikey-auth-challenge-v1.md:146-149`), so the protocol
   text is correct — but a redeem implementer who reuses
   `IdentiKey.fingerprint/1` to compute `holder(<fp>)` produces a
   value that never matches a correctly minted token, twice over
   (wrong preimage *and* stub hash). Worth one sentence at fold
   time or in `add-biscuit-runtime`'s brief.
2. **"the token identity" is undefined** (`spec.md:11`). The
   sibling design signs `{biscuit_hash, nonce, aud}`
   (`add-secret-tokenator/design.md:104`) but neither document
   pins which bytes `biscuit_hash` hashes (wire serialization?
   revocation ID of the last block?) nor the canonical encoding
   of the signed tuple. Acceptable to leave to
   `add-biscuit-runtime` since test vectors are `ikp-6yz.2`, but
   it must be pinned before two implementations exist.
3. **The hop-monotonicity SHALL is satisfied by construction.**
   "A hop SHALL NOT remove holder checks or widen rights"
   (`spec.md:55-56`) — biscuit attenuation cannot drop checks or
   widen rights mechanically. Harmless as a normative restatement
   (it gives reviewers a citable rejection hook, and the two
   rejection scenarios are good), just noting no verifier code is
   implied by it.
4. **Copy-out verifiability appears as a SHALL in the protocol
   delta** ("Copy-out SHALL be verifiable against that digest,"
   `spec.md:42-43`) while copy-out is otherwise specified in
   `secret-tokenator`. Deliberate duplication is fine — the
   profile is protocol-tier — but the fold should keep the two
   sentences saying the same thing when `add-secret-tokenator`
   evolves.

## What is solid

- Profile-scoped holder SHALL with an explicit non-application
  sentence — the precise fix for Grok finding 1, no overcorrection.
- Zero-hop redeem plus the second-provenance and
  Identikey-as-nextKey rejection scenarios: the spec now rejects
  both failure modes Grok predicted reviewers would face.
- Decision 1's layering (tokenator is a verifier application of
  agency, not a fourth crypto layer) and the D-5 boundary
  ("GitHub PATs are not our ciphertext," `design.md:36-41`).
- Elided-envelope MAY in "Secret bytes stay out of the token"
  (`spec.md:39-43`) encodes Duke's vault call at the right tier:
  the protocol permits the envelope; the host capability requires
  it.
- Rejected list matches the living protocol as it stands
  (unsigned mode already rejected at `identikey-capability-v1.md:101`).

## Implementer gaps (for the act nodes, not this fold)

- Canonical `biscuit_hash` + signed-tuple encoding (finding 2);
  dCBOR determinism conventions already exist in the protocol
  repo — use them.
- The holder fingerprint requires real Blake3 and dCBOR of the
  self-describing key; neither exists in Mjolnir today
  (`crypto.ex:24-29` is SHA-256; LEARNINGS 2026-08-19 records the
  same stub already 400s Recrypt). `add-biscuit-runtime` has a
  hard dependency on the Blake3 NIF or an equivalent.
- Nonce store semantics (single-use until `exp`) are named but
  live in the sibling change's redeem node.
- Test vectors remain `ikp-6yz.2`, including at least one vector
  for the Blake3-of-dCBOR fingerprint so the two-namespace trap in
  finding 1 is caught mechanically.

Fold may proceed: copy the ADDED requirements into
`identikey-capability-v1.md`, keep the three-layer table, point
the tokenator at `add-secret-tokenator`.
