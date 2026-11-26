# Tasks

Revision 3 (path trial). Product boxes stay open until a fresh advise accepts this contract. Spike boxes record what was run on 2026-11-26 and what was not. Logs redact tokens.

## Gate

- [x] Fresh advise of revision 3 at `82078ec767cab2bd24cb65c0b9ace201ec6595fe`: independent accept in `reviews/2026-11-26-advise-2.md`. Contract/trial only; PENDING remains PENDING. Do not treat this as activation, product completion or deployment authorization.

## Trial decisions (Duke, 2026-11-26: try the path)

These are the trial's contract. They are not an advise accept.

- [x] **ASK 1 Path, not claim.** Open and protected with the same owner and name are two identities for this trial. The claim revision stays history. No kind claim, no patched verifier, no `RoomKinds` store.
- [x] **ASK 2 Mixed mints.** Both succeed. No 409. No durable record. The cost is the second identity in D5.
- [x] **ASK 3 Marker.** Literal `~open`, outside the mint room alphabet.
- [x] **ASK 4 Mint authority.** Body field only, scope stays `relay:join`, owner is verified `sub`.
- [x] **ASK 5 Credentials.** A protected credential is used only on a protected join, including renewals. Handoff to `.15` and `add-call-e2ee`. Not built here.
- [x] **ASK 6 Enforcement.** The edge (`.13`) is the WebRTC gate. The buggy-edge residual is accepted and written in D4.
- [x] **ASK 7 Deploy.** Controller only, after accept. No relay deploy for this mechanism. Rollback is the previous mint plus fail-closed explicit-open clients. Outstanding open tokens live until `exp`.

## Spike (this revision)

- [x] **H-clock.** `spikes/logs/path-offline.log`. kio `Manual` clock installed on the runtime. `KeySet::verify` and `assess` both see it: admit at t0+599, `token has expired` at t0+600, future `iat` refused by `profile`, host clock refuses the manual-time token. Marker `%` and double-encoded spellings are outside the grant. Wide root is admitted on both paths.
- [x] **H-wt.** `spikes/logs/path-live.log`. Production decider, dummy key, literal `~open`. Open marker 14 frames / 266 bytes on the open root; protected marker 14 frames / 266 bytes on the protected root. Cross-root sessions `unauthorized`. Encoded and double-encoded paths `unauthorized`. Subscribe-only publish `unauthorized`. Wide token held on both URLs. Each announcement set named only its own marker.
- [x] **H-iroh, bounded pair.** `path-pair.log` / `path-follow.log`. Publisher ready, then `Node::subscribe` bounded at 6s. Open own-read 16 frames / 144 bytes `PAIR-OPEN`. Protected own-read 16 frames / 144 bytes `PAIR-PROT`. Both cross-reads and the protected read of a stolen path: `subscribe-timeout call=Node::subscribe`, not `unroutable`. One live announcement on the open subscribe token named only the open marker. Local publish byte counts are not delivery.
- [x] **H-chromium MoQ and HTTP boundary.** `path-chromium.log`: pinned `@moq/net` subscriber, literal open URL, `frames=20 bytes=380 first=mjolnir-relay-frame`. `new URL` kept `%7Eopen` and `%257Eopen` in `pathname`; those dials did not finish inside 15s. `path-mint-http.log`: Bandit called today's `Mint.issue`. `kind` is ignored, no response `kind`, root `t/<owner>/standup`, six claim names. `~open` and Bandit-decoded `%7Eopen` are 400 `bad_segment` with room param `~open`. `%257Eopen` stays room param `%257Eopen` and is also 400. Product `Router` does not compile (`authorize_app/4` and the deploy/record plugs).

## Mint (after accept)

- [x] `mint_test.exs` "open root": body `%{"kind" => "open"}` yields root `t/<owner>/~open/<room>`, claim names exactly today's six, response `kind` `open`. Red first.
- [x] `mint_test.exs` "protected root unchanged": omitted `kind` and `%{"kind" => "protected"}` yield `t/<owner>/<room>`, today's claim names, response `kind` `protected`. The existing first test gains one `kind` assertion and no claim-name change.
- [x] `mint_test.exs` "bad kind": `"Open"`, `"open "`, `""`, `nil`, `1`, `true`, `["open"]`, `%{}` are 400 `bad_kind` with and without the env file. Red first.
- [x] `mint_test.exs` log: validated `kind=open` or `kind=protected` only. A rejected raw value is absent. The token is absent.
- [x] Router test: body versus `x-room-kind` and `?kind=` . The root follows the body. `Cache-Control: no-store`.
- [x] Old-controller fixture, captured before the mint change: body `%{"kind" => "open"}` has no response `kind` and root `t/<owner>/<room>`. `.15` consumes it. Red is not expected; the fixture records today's silence.
- [x] Classifier unit corpus: the three-way table in D1, including wide, encoded, double-encoded, case-folded marker, and non-canonical owner. No product relay change.

## Docs

- [x] `docs/runbooks/edge-relay.md`: open roots are `t/<owner>/~open/<room>`; no relay deploy and no switch for this mechanism; wide tokens still span both. Controller-only deploy and rollback steps are written there and are not an authorization to run them.
- [x] `CLAUDE.md` relay line: body `kind`, the two roots, no kind claim. `Agents.md` has no copy of that route sentence, so it was left unchanged.
- [x] ADR 0019 marked with the advise verdict. It stays draft. Not folded.

## Production

No production step in this trial. After accept, the owner gate is a controller deploy only (`--app-only`), then an open mint whose root the live relay admits with `wt-session`, and a protected mint of the same name that does not see that broadcast. No test key is added to the production key set.

Handoffs in design D4 and D5 remain owned downstream; the release/preparation obligations below track their completion without marking those products built here.

## Owed by fresh path review (2026-11-26)

Review: `reviews/2026-11-26-advise.md`, contract `3a64e421`, send-back. These are contract/evidence corrections; no product activation or deployment grant.

- [x] R1: Design D4 and the edge-relay delta name full `assess` on one snapshot, original root, checks before relay I/O or SDP, expiry teardown, and exact expected full-root equality for both kinds on join, replacement, and renewal. The pure classifier stays separate. Fresh advise still owes the accept.
- [x] R2: Relay-room-auth delta now has the complete MODIFIED room-path requirement: both roots, relative WebTransport, absolute Iroh, participant confinement, sibling isolation, HTTP segment behavior kept.
- [x] R3: D5 records `.15` fail-closed before open issuance, versioned full-root KDF before encrypted open, full-root roster and metering before those paths ship, and TURN class `c2` in `<unix>:<class>.<owner>[.<room>.<participant>]`. Until that TURN task lands, open rooms get no TURN username. Plaintext open does not wait on E2EE. No deploy approval.
- [x] R4: Evidence in `spikes/path/finding.md` (section after `fea6caf6`). Browser MoQ receipt is 20 frames of `mjolnir-relay-frame`. Iroh positives are `PAIR-OPEN` and `PAIR-PROT`. Cross-root Iroh is a bounded `Node::subscribe` timeout beside that positive control, not a refusal string. HTTP spellings are today's mint through Bandit. WT `q/track` was admitted and not announced; `p/track` was received. Encoded browser pathnames did not collapse. Repeat against the future open mint is still owed. Fresh advise remains unchecked.

## Implementation and downstream gates retained by fresh accept (2026-11-26)

The historical R1–R4 wording above records the author's amendment. Fresh advise is now checked only at the Gate above. Its independent sustained-publisher check supersedes the weak serial Iroh timing in `path-pair.log`; see `reviews/2026-11-26-advise-2.md` and its adjacent check log.

- [x] Before product HTTP validation: `mix test` on Elixir 1.20.4 / OTP 29 compiled `Mjolnir.API.Router` and the mint tests. No auth helper was edited. `MIX_ENV=dev mix run` still loads stale `_build/dev` beams and reports `authorize_app/4`; that is the cache the review already compiled past, not a source gap. Bandit in `relay_mint_router_test.exs` records path_info: literal `~open` and `%7Eopen` both dispatch `~open`; `%257Eopen` stays `%257Eopen`; all three are 400 `bad_segment`.
- [ ] Before implementation acceptance: `spikes/logs/path-mint-live.log` uses `Mint.issue` tokens on a disposable local relay. Iroh own-reads: `MINT-OPEN` and `MINT-PROT`, 11 frames / 99 bytes. WT own-reads: 15 frames / 285 bytes on `alice/marker` for each root. WT cross-root is `unauthorized`. Iroh cross-root is exit 124 (`Node::subscribe` timeout), not a refusal string. Publishers were ready for the own-reads; they had finished their 14s before the later bob read, so that timeout is not participant confinement. Bob's WT publish of `alice/marker` printed local bytes and exit 0; no subscriber confirmed delivery. Browser MoQ was not repeated: the pinned JS checkout has no built bundle, and disk was about 3 Gi. Resubscribe-on-announce is unchanged. No renewal implementation.
- [ ] `.13` preparation and release: reconcile its contract to D4 full admission from one validated key snapshot, original root, expected invitation identity, operation checks before I/O/SDP, and expiry teardown. Test wrong owner/room/kind and response/token mismatches on join/replacement/renewal; retain key-unavailable/drain fail-closed behavior.
- [ ] Before first open issuance, `.15` client guard: `Mjolnir.Relay.RoomJoin.check/3` is the reusable check (join, replacement, and renewal share it). `mjolnir-rurh.15` and `mjolnir-rurh.5` have no landing tree in this repo, so the guard is not wired to a page. That wiring is still this gate. Explicit-open on an old mint response (no `kind`, protected root) returns `:open_refused`. A protected ask does not accept an open root.
- [ ] Before encrypted open, `add-call-e2ee`: reconcile versioned full-root invite/KDF context, incompatible-version refusal and same-secret cross-kind vectors in both directions. Protected-only E2EE and plaintext open do not wait for this.
- [ ] Before open roster/accounting, `.14`/`.4`: reconcile full-root membership and usage attribution and test same-owner/name siblings. No sibling mixing; tenant-wide aggregation remains deliberate and must not permit quota evasion.
- [ ] Before integrating TURN with open issuance, `add-turn-service`: reconcile its current unconditional configured-room `c1` response with D5. Omit open TURN credentials until explicit `c2.<owner>.<room>.<participant>` support lands; then test equal-expiry sibling inequality, delimiter/collision behavior and existing expiry limits. TURN is not MoQ admission and has no deployment grant here.
- [ ] After implementation and readiness evidence, obtain separate controller deployment authorization and run the real-mint/live validation. Fresh advise and the path trial do not satisfy this gate.
