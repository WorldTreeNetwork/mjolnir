# Independent code review — send-back

Reviewed implementation: **0d1b3f0a57286b2c1e55cec0722c39daa27ec226**.
Reviewer: independently assigned Codex review sub-agent; no nested agents.
Contract: `82078ec767cab2bd24cb65c0b9ace201ec6595fe`, accepted by
`2026-11-26-advise-2.md`. This is code review, not a reconsideration of the
accepted signed-path architecture. No product edits, production access,
deployment, node closure or fold.

## Implementation findings

### R1 — P1: RoomJoin authenticates nothing before returning a trusted-looking success

`lib/mjolnir/relay/room_join.ex:22–27,42–48` extracts `root` from base64 JSON,
ignores both header and signature, and passes that unverified string to the
classifier whose documented input is a verified root. `check/3` has no trusted
key, admission result or verifier input, and no caller supplies verification.
An arbitrary `not-a-header.<payload>.` with the expected root succeeds, even
without expiry, issue time or grants. An expired payload also succeeds. The
existing positive fixtures explicitly use `exp: 1` and signature `sig`.

This does not bypass the unchanged relay verifier today: the helper is unwired
and the relay still authenticates sessions. It does make the proposed client
guard unsafe to treat as authorization to import a protected credential or
choose a media mode. D1/D5 require verified classification; expected-root
equality alone proves no authenticity.

**Fix:** make the trust boundary explicit in the API. Have the identity check
consume the original root from an authenticated admission result supplied by a
trusted producer, tied to the exact credential being installed, and compare
that root to independently supplied invitation context and response metadata.
Do not derive that authority by decoding the response token. If the raw-token
decoder is retained for preflight diagnostics, name/document its output as
unverified and prevent its success from being the verified join decision.
Do not build a second gateway verifier here: full `assess`, its trust snapshot,
grant/operation checks and expiry lifecycle remain `.13` work. An unwired
trusted-result seam must remain documented as unwired, not authentication
implemented. Add tests that cannot use an unsigned/expired dummy JWT as proof
of verified success; retain mismatch/old-controller cases at the identity seam
and require authentication failures at the eventual integration boundary.

### R2 — P2: malformed JWT payload types raise instead of returning a refusal

`lib/mjolnir/relay/room_join.ex:46–47`: successful JSON decoding does not imply
a claims object. Payloads `[]`, `[1]`, `"text"`, `1`, and `true` raise through
`claims["root"]` rather than returning `{:error, :bad_token}`. The public API
promises an error tuple and is supposed to surface a failed join, not crash its
caller on malformed remote input. Independent probes reproduce all five.

**Fix:** remove this parser as part of R1, or require `is_map(claims)` before
access and fail closed for every other JSON type. Add malformed base64/JSON,
scalar, array, null and missing/non-string root cases, with explicit assertions
that no exception escapes.

### R3 — P2: present invalid response kinds are silently treated as absent

`lib/mjolnir/relay/room_join.ex:70–76,87–91`: `response["kind"] ||
response[:kind]` loses field presence and treats `false` and `null` as the old
mint's missing field. Both yield success for a protected root. The accepted
contract permits legacy omission, not a present non-enum value; any supplied
kind must agree with the authenticated identity. This is a consistency defect,
not a demonstrated protected-to-open transition.

**Fix:** distinguish absent keys from present values with `Map.fetch` (including
the supported atom-key representation). Permit omission only for legacy
protected responses; reject present null/boolean/number/list/object values and
conflicting dual-key representations. Retain exact enum comparison and explicit
open's mandatory `"open"` metadata. Add these cases to the unit corpus.

## Acceptance coverage and test quality

- **Mint passes this review:** body-only exact enum/default; bad kind before
  environment/key access and after segment/TTL type checks; protected root
  unchanged; owner still comes from verified caller sub; no kind JWT claim,
  store, new grant or verifier change. Independently verified EdDSA signatures
  for omitted, explicit protected and explicit open; all six claim names and
  participant publish/room subscribe grants match. Additional missing-env
  probes cover every bad-kind category plus floats, false and newline.
- **HTTP passes focused checks:** actual Router and Bandit tests exercise body
  versus query/header, authenticated owner binding, no-store on mint success,
  and observed raw/dispatched marker spellings. Router uses `body_params`, not
  merged query params. No-store behavior is unchanged for errors. Log code
  interpolates only validated kind, not raw input or token; focused tests check
  open and rejected values. The protected log branch shares that code.
- **RoomClass passes:** literal slash and exact arity, canonical 32-byte base58
  round-trip with no trimming, exact room alphabet. Independent boundary
  probes cover all-zero owner, wrong byte lengths, 64/65-character room limits,
  newline, Unicode and trailing/empty segments. Wide and encoded roots remain
  invalid; ordinary `open` and `_open` remain protected.
- **Identity comparison works only as an unverified consistency check today:**
  independently supplied expected-root argument rejects wrong owner, room and
  sibling kind; response root/kind disagreement and explicit-open old mint
  are refused. With the correct expected open root, old mint returns
  `:unexpected_root`; `:open_refused` occurs when expected root is protected.
  Both stop this helper. Missing kind on an open-shaped root also refuses.
- **Lifecycle coverage is not present:** the test named “join, replacement,
  and renewal” repeats the same pure function with an unused `_step`. It does
  not exercise three callers, credential storage, reconnect, media startup or
  preservation of an existing session on renewal refusal. Those tests cannot
  catch a caller skipping the check. Existing JWT fixtures also cannot detect
  the authentication regression in R1. Add realistic lifecycle checks when
  the client adapter exists; do not claim them from this loop.

## Integration and release gates, separate from the fixes

Repository searches found no product caller of RoomJoin and no direct caller
of RoomClass except RoomJoin. The unchanged Rust CLI sends `{}` and deserializes
only `token`; extra response fields are compatible and it still requests
protected rooms. An Elixir module is not a browser-executable client guard.
The stated lack of `.15`/`.5` landing code means this is at most a reference or
server-side seam until an actual browser adapter implements the same contract
and obtains authenticated identity. Reuse requires either that adapter or a
defined trusted server boundary, plus tests at the actual three lifecycle
entry points. Keep first open issuance gated on that work. No finished page
is required just to fix these helper defects or implement the mint.

The current native relay `assess` still verifies keys, algorithm, profile,
path containment and grants; this commit does not alter it. Full gateway
admission before relay I/O/SDP, expiry teardown and one-snapshot semantics
remain future `.13`. No open TURN credentials, encrypted-open KDF changes,
roster or metering integration are established here. Existing tasks already
retain those release gates, so no duplicate tasks were added.

At the reviewed hash, `path-mint-live.log` establishes product-minted own-root
receipts but explicitly lacks sustained participant confinement and browser
repetition. The builder owns the concurrent replacement evidence and the two
reported full-suite failures (Reconcile local thaw socket; Aie Execute
SUN_LEN). Neither was rerun or assumed fixed here. Do not promote the builder's
reported 2002 passed / 82 excluded / 2 failures into a green full-suite result.
Review the new evidence separately with its provenance and live-positive
controls before checking the existing implementation-evidence gate.

## Independent checks

On the reviewed checkout, `mix test test/mjolnir/relay/mint_test.exs
test/mjolnir/relay/room_class_test.exs test/mjolnir/relay/room_join_test.exs
test/mjolnir/api/relay_mint_router_test.exs`: **26 passed**, seed 536050.

`MIX_ENV=test mix run --no-start --no-compile
openspec/changes/add-open-room-kind/reviews/2026-11-26-code-probes.exs`:
**7 passed**, seed 599819. Adjacent probes assert observed defects as well as
positive controls; their passing is reproduction evidence, not acceptance.
Logs are adjacent in `2026-11-26-code-checks.log`. No large/native rebuild or
builder harness change. Local shell is Elixir 1.20.4/OTP29; this is not evidence
for the repository's missing pinned 1.20.5/OTP27 toolchain.

Read root/OpenSpec AGENTS, bd prime, accepted design/deltas/prior review,
living room-auth contract, the full implementation diff and relevant unchanged
router, Owner/Base58, CLI and native admission code. Scope stayed small.

**Safe next step:** parent fixes R1–R3 and focused regression tests, then checks
the builder's separate evidence. Keep `mjolnir-rurh.11` open and unfolded;
client integration and separate deployment authorization remain required.
