# Tasks

Revision 3 (path trial). Product boxes stay open until a fresh advise accepts this contract. Spike boxes record what was run on 2026-11-26 and what was not. Logs redact tokens.

## Gate

- [ ] Fresh advise of revision 3. No product code before an accept. Do not treat the path trial as activation.

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

- [ ] `mint_test.exs` "open root": body `%{"kind" => "open"}` yields root `t/<owner>/~open/<room>`, claim names exactly today's six, response `kind` `open`. Red first.
- [ ] `mint_test.exs` "protected root unchanged": omitted `kind` and `%{"kind" => "protected"}` yield `t/<owner>/<room>`, today's claim names, response `kind` `protected`. The existing first test gains one `kind` assertion and no claim-name change.
- [ ] `mint_test.exs` "bad kind": `"Open"`, `"open "`, `""`, `nil`, `1`, `true`, `["open"]`, `%{}` are 400 `bad_kind` with and without the env file. Red first.
- [ ] `mint_test.exs` log: validated `kind=open` or `kind=protected` only. A rejected raw value is absent. The token is absent.
- [ ] Router test: body versus `x-room-kind` and `?kind=` . The root follows the body. `Cache-Control: no-store`.
- [ ] Old-controller fixture, captured before the mint change: body `%{"kind" => "open"}` has no response `kind` and root `t/<owner>/<room>`. `.15` consumes it. Red is not expected; the fixture records today's silence.
- [ ] Classifier unit corpus: the three-way table in D1, including wide, encoded, double-encoded, case-folded marker, and non-canonical owner. No product relay change.

## Docs

- [ ] `docs/runbooks/edge-relay.md`: open roots are `t/<owner>/~open/<room>`; no relay deploy and no switch for this mechanism; wide tokens still span both.
- [ ] `CLAUDE.md` relay line: body `kind`, the two roots, no kind claim.
- [ ] ADR 0019 marked with the advise verdict when it exists. It stays draft until then.

## Production

No production step in this trial. After accept, the owner gate is a controller deploy only (`--app-only`), then an open mint whose root the live relay admits with `wt-session`, and a protected mint of the same name that does not see that broadcast. No test key is added to the production key set.

Handoffs in design D4 and D5 are not boxes here.

## Owed by fresh path review (2026-11-26)

Review: `reviews/2026-11-26-advise.md`, contract `3a64e421`, send-back. These are contract/evidence corrections; no product activation or deployment grant.

- [x] R1: Design D4 and the edge-relay delta name full `assess` on one snapshot, original root, checks before relay I/O or SDP, expiry teardown, and exact expected full-root equality for both kinds on join, replacement, and renewal. The pure classifier stays separate. Fresh advise still owes the accept.
- [x] R2: Relay-room-auth delta now has the complete MODIFIED room-path requirement: both roots, relative WebTransport, absolute Iroh, participant confinement, sibling isolation, HTTP segment behavior kept.
- [x] R3: D5 records `.15` fail-closed before open issuance, versioned full-root KDF before encrypted open, full-root roster and metering before those paths ship, and TURN class `c2` in `<unix>:<class>.<owner>[.<room>.<participant>]`. Until that TURN task lands, open rooms get no TURN username. Plaintext open does not wait on E2EE. No deploy approval.
- [x] R4: Evidence in `spikes/path/finding.md` (section after `fea6caf6`). Browser MoQ receipt is 20 frames of `mjolnir-relay-frame`. Iroh positives are `PAIR-OPEN` and `PAIR-PROT`. Cross-root Iroh is a bounded `Node::subscribe` timeout beside that positive control, not a refusal string. HTTP spellings are today's mint through Bandit. WT `q/track` was admitted and not announced; `p/track` was received. Encoded browser pathnames did not collapse. Repeat against the future open mint is still owed. Fresh advise remains unchecked.
