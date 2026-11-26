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
- [ ] **H-iroh, complete pair.** Publish connected on both absolute roots (380 bytes reported). One protected own-read returned 1 frame / 19 bytes. One cross-subscribe returned `unroutable`. The open own-read and the other cross-read did not return within 12s (`killed-after-12s`). A later paired run (`path-live-extra.log`) did not deliver frames to either reader within 8s, including the open own-read, while publishers still printed local byte counts. A protected reader of an open token's `stolen` path also returned no frames before the kill. Do not treat local `published bytes=` as relay delivery.
- [x] **H-chromium, WebTransport layer only.** `path-live-extra.log`. Headless Chrome for Testing, `serverCertificateHashes` of the harness ECDSA leaf, literal open URL: `ready wrote=20` on a unidirectional stream. That is not a MoQ frame at a subscriber. Encoded and double-encoded page URLs also readied, because the test page's query decoding plus the WebTransport URL parser collapses `%7E` and `%257E` to `~` before the request. The native WT refusals are the encoded-path evidence. HTTP mint spellings were not executed: `mix run` did not compile this tree (`Mjolnir.API.Auth.term_cookie/0` missing). The room alphabet in `mint.ex` still excludes `~` and `%`.

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

- [ ] R1: Specify .13 full relay admission (validated trust snapshot, verification, profile/time/TTL, root/path and grant checks), original root return, operation checks before side effects, and leg expiry. Specify both-kind expected full-root and response/token binding for joins, credential replacement and renewal, with wrong-owner/room/kind fixtures and visible refusal; preserve the pure classifier.
- [ ] R2: Add the complete MODIFIED room-path requirement with both roots, transport spellings, participant confinement and sibling isolation, preserving protected/HTTP behavior.
- [ ] R3: Record concrete downstream preparation/release obligations: .15 fail-closed before open issuance; versioned invite/KDF binding and cross-kind vectors before encrypted open; full-root roster/metering before their affected paths ship; reconcile TURN's actual dot-separated grammar with a versioned noncolliding identity and equal-expiry sibling tests (or explicitly disposition aggregate accounting).
- [ ] R4: Finish/reconcile author-owned browser MoQ receipt, paired Iroh positive and negative controls, HTTP spellings, and WT in-session opposite-root operations/announcements. Capture relevant wire spellings and pin evidence. Do not use raw stream writes, local publish byte counts or timeout-without-positive-control as delivery/refusal proof. Repeat with actual mint output after implementation. Fresh advise remains owed after these amendments.
