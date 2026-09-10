# Advise — add-secret-tokenator (architecture, cross-family accept read)

> **ADVISE:** accept-with-nits

Reader: Fable 5. Cross-family accept reader per ADR-005 (Grok
authored ADR 0008; Grok's own 2026-08-26 review was send-back).
Sibling `update-identikey-capability` is accept-with-nits this
same date, so Grok finding 2 (blocked on protocol) is cleared.

Signed result: `permission: write` (reviews only), `disposition: task-green`.

Date: 2026-08-26. Scope: `proposal.md`, `design.md`, `tasks.md`,
`specs/secret-tokenator/spec.md`, ADR 0008
(`docs/decisions/0008-secret-tokenator.md`), Grok review
`reviews/2026-08-26-advise.md`, `lib/mjolnir/secret_store.ex`,
`lib/mjolnir/api/auth.ex`, `lib/mjolnir/sites/identikey.ex`,
`lib/mjolnir/sites/crypto.ex`, `docs/LEARNINGS.md`, sibling
protocol change and its review.

## Verdict

Accept, with nits. Every Grok send-back box marked done on
`tasks.md` is verifiably closed in the amended text (checked
against the spec/design, not the checkboxes). Duke's 2026-08-26
vault call is faithfully encoded: owner-signed Gordian envelope
with the secret assertion elided in flight (`spec.md:26-33`,
`design.md:27-36`), copy-out as the v1 superset with proxy-only
explicitly rejected (`spec.md:48-56,66-71`, `design.md:131-137`),
thin proxy named as the more-secure pattern, not required. The
Auth fourth branch is in both design and spec with a skip-auth
rejection scenario. The nits below are code-reality corrections
and implementer gaps for the act nodes; none change a SHALL.

## Send-back closure check

- **Auth plug fourth branch, not skip_auth.** Closed. Design
  Decision 2 names the fourth `call/2` branch and cites the trap
  (`design.md:89-95`); the spec both requires the dedicated
  branch and carries a rejection scenario for adding
  `/api/secrets/redeem` to `@skip_auth_paths` (`spec.md:73-79,
  89-94`). Verified against code: `@skip_auth_paths` is only
  `/api/health` (`lib/mjolnir/api/auth.ex:34`) plus the `/auth/*`
  prefix (`auth.ex:66-68`).
- **Holder fingerprint encoding.** Closed via the sibling
  protocol amend (auth-challenge §5 fingerprint, verified in that
  review).
- **Reused nonce fails closed.** Closed. Design step 1
  (`design.md:101-103`) and the spec requirement "Missing, wrong,
  expired, or **reused** nonce SHALL return no secret" with a
  dedicated reused-nonce scenario (`spec.md:103-108, 123-128`).
- **Vault is owner envelope, not host-global opaque; secret_id
  path-safe.** Closed. `spec.md:3-10` (SHALL be `SecretStore.put`,
  SHALL NOT be `put_opaque`, path-safe `secret_id`, guests cannot
  write); `design.md:37-41` keeps opaque for Buzz nsec only,
  consistent with LEARNINGS mjolnir-1pe (envelope API cannot hold
  an *unsigned* nsec — a signed envelope around a PAT is not that
  case).
- **Copy-out to RAM/tmpfs, not virtio-fs; thin proxy named.**
  Closed. `design.md:139-142`, `spec.md:53-56`, and the fat-agent
  snapshot scenario (`spec.md:58-64`).

## Steelman against

**Proxy-only v1: forbid copy-out and make the PAT-leak class
unrepresentable.** Strongest version: every copy-out is a chance
for the PAT to land on a virtio-fs rootfs and be cloned into
every snapshot; the spec's own scenario admits Z can violate the
tmpfs rule ("unless Z wrote them there in violation,"
`spec.md:63-64`) — a SHALL the verifier cannot enforce is a
wish. A thin proxy that is the sole holder makes the leak
structurally impossible rather than procedurally discouraged.

Why it fails: the proxy does not make the leak unrepresentable —
the proxy VM holds the PAT in RAM and has its own snapshot
surface; copy-out has merely moved, not vanished. Proxy-only also
forces every consumer to build an upstream-specific proxy (a
GitHub proxy means fronting enough of the git+API surface to be
useful) before any value ships, and the proxy is itself a
consumer of copy-out (`design.md:176-179`) — so forbidding
copy-out in v1 forbids the thing the proxy is built from. Duke's
superset framing is correct: copy-out is the primitive, the proxy
is the hardening pattern, and the spec rejects both inversions
(forbid-copy-out at `spec.md:66-71`; omit-the-pattern named wrong
at `design.md:136-137`).

## One real tradeoff

**Redeem in the BEAM couples secret availability to control-plane
deploy cadence.** Decision 2 puts redeem on `api_url` because the
vault is in-process SecretStore state and a second binary opening
the same 0600 files is a new trust boundary (`design.md:63-69`) —
the right call. The cost is real and should be held with eyes
open: every Elixir restart (`just deploy` → Cleanup kills VMs →
Reconcile resumes) is also a tokenator outage, so an agent
mid-challenge loses its nonce and an agent mid-redeem fails
closed. Blob door exists precisely to escape that coupling for
blobs. For secrets the coupling is accepted because redeems are
rare, retryable, and fail closed — but if redeem volume ever
grows past "fetch a PAT at task start," the pressure to split a
sidecar returns, and this ADR is the document that must be
revisited rather than quietly bypassed with a second vault.

## Findings (nits — none block accept)

1. **`verify_envelope/2` is mischaracterized, and the real
   day-one failure mode is different from the one named.** Design
   says "Signature verification on SecretStore is still stubbed
   (`verify_envelope/2`)… Do not pretend it verifies today"
   (`design.md:42-46`). In fact `put/3` verifies before every
   write (`secret_store.ex:237-240`), and `verify_envelope/2`
   Ed25519-verifies **JSON** envelopes against the registered
   `identity/pubkey` record (`secret_store.ex:599-618, 640-650,
   653-668`); what is stubbed is the recrypt MultiSig/ML-DSA leg
   and Blake3 (`identikey.ex:6-8`, `crypto.ex:24-29`). The
   consequence the deposit act node will actually hit: a real
   Gordian envelope is dCBOR, so `Jason.decode` fails and
   `SecretStore.put` returns `{:error, :bad_envelope_json}`
   (`secret_store.ex:600-602`) — deposit of the very artifact
   this design specifies is rejected today, and deposit also
   requires a prior `identity/pubkey` bootstrap record
   (`secret_store.ex:653-656`). That is fail-closed, so the
   architecture is safe, but `add-capability-mint` must extend
   `verify_envelope/2` for Gordian bytes (or define a JSON
   serialization), not merely "wire MultiSig."
2. **Blake3 is SHA-256 on this host; the digest story has a hard
   dependency.** `Sites.Crypto.blake3_hash/1` is a SHA-256
   placeholder (`crypto.ex:24-29`); LEARNINGS 2026-08-19 records
   the same stub already 400-ing Recrypt against the blob door.
   Recipient-side digest verification (`spec.md:26-33`) runs
   client-side so the host stub does not block *that*, but
   mint-side elision and any host-side digest computation do.
   `add-biscuit-runtime` inherits a real-Blake3 prerequisite.
3. **Fourth-branch ordering is a security property; say it in
   the act node.** Sites tokens are checked first so a narrow
   credential is never upgraded by connecting from loopback
   (`auth.ex:20-24, 49-63`). The Biscuit branch needs the same
   slot: a request presenting a Biscuit must get redeem-only
   scope even from `127.0.0.1`, i.e. the branch goes before
   `localhost_bypass?`, not after. The spec requires the branch
   confer "redeem (and challenge) only" (`spec.md:76-79`) but
   does not pin the ordering; the moduledoc principle should be
   cited when `add-tokenator-redeem` lands.
4. **What credential enters the branch at `POST
   /api/secrets/challenge`?** The holder proof does not exist yet
   at challenge time (the nonce is what gets signed,
   `design.md:100-104`), and challenge is deliberately not
   skip-auth. Presumably the Biscuit itself is presented at
   challenge; the design does not say. Pin it, and bound the
   nonce store (an unauthenticated-ish challenge endpoint is
   otherwise a nonce-mint memory surface for anyone on the
   overlay).
5. **The copy-out scenario oversimplifies the digest check.**
   "Blake3/envelope digest of V equals D" (`spec.md:37-40`) reads
   as digest-of-raw-bytes, but a Gordian elision digest commits
   to the assertion subtree (and its salt, if salted — and a
   low-entropy secret behind an unsalted elided digest is
   dictionary-attackable from the digest alone). The design
   already gestures at the fix — copy-out returns "enough
   envelope to verify the digest" (`design.md:132-133`) — so the
   requirement text is fine; the redeem node must return the
   assertion structure, not a bare string, and mint should salt.

## What is solid

- The vault call: envelope-not-opaque gives copy-out a
  commitment to verify against, reusing the elision convention
  the stack already has, instead of inventing an ad-hoc digest
  scheme on raw `put_opaque` bytes.
- Guest write-denial is grounded in code that exists: guests on
  `10.200.0.1:4000` cannot take the loopback bypass
  (`auth.ex:139-143`), and the spec still refuses to rely on it
  by requiring owner-auth deposit (`spec.md:12-24`).
- No `tokenator_url`, no new overlay port, and the extra-port
  rejection scenario (`spec.md:96-101`) — the INPUT-trap lesson
  from :5432/:7222 stays learned.
- Decision 4 names the D-5 objection and takes it explicitly for
  foreign secrets only; metadata-not-value logging is a SHALL
  with a failed-redeem scenario (`spec.md:130-140`).
- Decision 5 (reuse until TTL/rotation; single-use as a later
  Datalog check + injected fact) resists building a second
  ledger prematurely.
- The 2026-08-16 fold discipline is written into tasks.md itself
  (`tasks.md:23-27`): no unimplemented HTTP SHALLs into the
  living spec.

## Implementer gaps (for the act nodes)

- `verify_envelope/2` Gordian/dCBOR extension + owner
  `identity/pubkey` bootstrap as a deposit precondition
  (finding 1) — `add-capability-mint`.
- Real Blake3 (finding 2) and the two-fingerprint-namespace trap
  (holder fp is Blake3-of-dCBOR-map; `IdentiKey.fingerprint/1` at
  `identikey.ex:75-77` is stub-hash-of-raw-bytes and must not be
  reused for `holder(<fp>)`) — `add-biscuit-runtime`.
- Auth branch ordering and challenge-time credential
  (findings 3–4) — `add-tokenator-redeem`.
- Canonical `biscuit_hash` and signed-tuple encoding for
  `{biscuit_hash, nonce, aud}` (`design.md:104`) — shared with
  the protocol change; pin via dCBOR conventions before two
  implementations exist.
- Copy-out response shape: assertion subtree incl. salt, not
  bare bytes (finding 5) — `add-tokenator-redeem`.
- Nonce store bounds and eviction at `exp` — `add-tokenator-redeem`.

Do not fold unimplemented HTTP SHALLs into the living spec; fold
the architecture-true requirements per tasks.md. ADR 0008 may move
to Accepted with the pointer from `docs/architecture.md`.
