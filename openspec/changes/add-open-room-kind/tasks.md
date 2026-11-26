# Tasks

Each test below is written first and seen to fail for the stated reason before the code that makes it pass. Logs and captured runs go under `evidence/` in this change. No box closes on reasoning alone.

## Gate

- [ ] Advise accept recorded in `reviews/` (Astra per Duke's 2026-11-25 preference; Fable if the orchestrator follows the ladder for protocol blast). No product code before it.
- [ ] **ASK** Reading of the owner's decision: the "signed claim in the room token" is the existing signed `root` claim, carrying a reserved `~open` segment (`t/<owner>/~open/<room>`), not a new `kind` claim, and no controller store. Reason: the pinned moq-auth refuses unknown claims (`wire.rs:21`), so a new claim breaks every deployed relay and needs a moq-auth patch, and it would still need a store to keep the kind the same for every participant. The root makes a mixed mint harmless (two rooms). Recommendation: **yes**.
- [ ] **ASK** Marker spelling `~open` (URL-unreserved, outside the room alphabet). Recommendation: **`~open`**, subject to H1. Fallback `@open` or `+open` if H1 fails.
- [ ] **ASK** No new scope for opening a room: `relay:join` and the owner from `sub`, as today. Recommendation: **no new scope**. Per-kind cost and limits go to metering (`mjolnir-rurh.4`).
- [ ] **ASK** Encryption in an open room: the browser clients (`.5`, `.15`) offer no E2EE in an open room, because WebRTC cannot play it and the `call-e2ee` context does not include the kind (design D6). The mint enforces nothing. Recommendation: **clients do not offer it; record on `.15` and `.5`**.
- [ ] **ASK** Production deploy order. Recommendation: **controller only**. (1) The orchestrator confirms the deployed relay commit and the compatibility boxes below pass against it. (2) `./scripts/deploy.sh root@45.76.77.97 --app-only` (hot cutover, VMs untouched). (3) Verify on production as in the last box. (4) No relay deploy. The edge (`.13`) ships later under its own gate. Rollback: the controller alone. Open tokens already issued stay valid until `exp` and name rooms no protected client uses. If H2 fails: relay first (`--relay`, drain), then the controller.

## Hypotheses (spike before act)

- [ ] H2: the orchestrator records the commit of the relay binary running on production (release metadata or the `mjolnir-relay` build stamp; no builder production access needed). A test built from `native/mjolnir_relay` at that commit, in a scratch worktree, admits the open fixture token (see "Compatibility") on `assess` and `web_grant` at `t/<owner>/~open/R` and gives a non-empty `ext_grant` publish of `t/<owner>/~open/R/P/**`. Log `evidence/h2-deployed-relay.log`. Red first: the same test with a token rooted `o/<owner>/R` is refused, to show the harness can fail.
- [ ] H1: on the laptop, with tokens from the new mint, `wt-session` and `iroh-publish`/`iroh-subscribe` publish and receive in `t/<owner>/~open/standup`, and the spike's Chromium page (`add-webrtc-edge/spikes/pages`, run unchanged) connects over WebTransport at that root with `?jwt=`. Log `evidence/h1-tilde-root.log`. If any leg fails, stop and amend the marker (ASK above) before the code tasks.

## Relay crate (`native/mjolnir_relay`)

- [ ] `room_kind(root) -> Option<RoomKind { kind: Open | Protected, owner, room }>` in `lib.rs`. Red first: test `room_kind_reads_only_exact_room_roots` with the eight roots from the "Reading roots" scenario, failing to compile and then failing on each case until implemented. No change to `profile`, `assess`, `web_grant` or `ext_grant`, and their existing tests pass unmodified.
- [ ] Isolation with the marker: test `open_and_protected_rooms_of_one_name_are_apart`, modelled on `room_rooted_token_isolates_rooms_and_participants_on_both_deciders`. An open token for `standup` is refused by `assess` and `web_grant` at `t/<owner>/standup`. A protected token for `standup` is refused at `t/<owner>/~open/standup`. Neither `ext_grant` contains the other root. Red first: the test asserts `room_kind` values, so it fails before `room_kind` exists. The isolation asserts themselves are expected to pass on the current code, and the log says so.

## Mint (`lib/mjolnir/relay/mint.ex`)

- [ ] `mint_test.exs` "open kind roots under ~open": body `%{"kind" => "open"}` gives root `t/<owner>/~open/standup`, response `kind: "open"`, claim names exactly the six from the existing test, publish `alice/**`, subscribe `**`. Red first: fails on the root.
- [ ] `mint_test.exs` "protected is the default and explicit": no body and `%{"kind" => "protected"}` both give `t/<owner>/standup` and `kind: "protected"`. The existing first test ("omitted ttl uses the ceiling…") passes **unmodified** except for one added `kind` assertion. Red first: fails on the missing `kind` key.
- [ ] `mint_test.exs` "bad kind is 400 before env": each of `"Open"`, `"open "`, `""`, `nil`, `1`, `true`, `["open"]`, `%{}` is `{:error, 400, "bad_kind"}` with a valid env, and again with the env file deleted (which proves the order: 400 before 503). Red first: today these mint successfully or answer 503.
- [ ] `mint_test.exs` "marker is not a segment": room `~open` and participant `~open` are `{:error, 400, "bad_segment"}`. This is expected to pass on the current code. Record that it passed first, as the last change recorded its missing-file test.
- [ ] `mint_test.exs` log line contains `kind=open` and does not contain the token (`capture_log`). Red first.
- [ ] Router-level test, not in tree today (`test/mjolnir/api/relay_mint_route_test.exs`, or the existing router test file if one covers this route): with header `x-room-kind: open` and with `?kind=open` and no body `kind`, the minted root has no `~open` and `kind` is `protected`. With body `{"kind":"open"}` the response is 200 with `Cache-Control: no-store` and `kind: "open"`. Red first: the `kind` key is absent. If the route cannot be driven without the auth plug in tests, record that and cover the query case by asserting `conn.body_params` excludes query params under the router's parser configuration.

## Compatibility

- [ ] Token minted before this change: at the parent commit of the mint change, mint one protected token for a fixed owner with the test key, and save it with its public key as `native/mjolnir_relay/tests/fixtures/mint-pre-kind.json` (token, public JWK, owner, room, label, `iat`/`exp`). Relay test `pre_kind_token_is_protected_and_admitted`: verification is done with `exp` checked against a clock pinned inside the token's life (or with `profile` given a `now` inside it), and `room_kind` is Protected R. Red first: fails to compile until `room_kind` exists.
- [ ] Open fixture: the new mint's open token saved as `tests/fixtures/mint-open-kind.json`, used by H2 and by a HEAD relay test asserting the same admission as H2.
- [ ] Claim set unchanged: a test decodes a protected token from the new mint and asserts its claim names and root equal the pre-change fixture's, apart from `iat`, `exp` and `jti`.

## Edge gate, captured (journey evidence; the product edge is `.13`)

- [ ] With a local, uncommitted patch to the spike edge (`add-webrtc-edge/spikes/rust/src/bin/edge.rs`: call `room_kind` after `assess`, answer 403 `room_not_open` unless it is Open, and match the URL `<room>` to `RoomKind.room`), run on the laptop. A protected token gets 403 `room_not_open` for WHIP `alice/cam` and for WHEP `carol/cam`, with no SDP answer and no relay session in the edge log. An open token for the same room name gets WHIP admitted and WHEP playing a native publisher at `t/<owner>/~open/r1`. Save the patch as `evidence/edge-gate.patch` and the run as `evidence/edge-gate.log`. Do not commit the patch into `add-webrtc-edge`. Red first: the unpatched edge admits the protected token's WHIP (S7 behaviour), shown in the same log.

## Docs and fold inputs

- [ ] `CLAUDE.md` relay line: the room mint takes optional body `kind` (`open`/`protected`, default protected), and an open root is `t/<owner>/~open/<room>`.
- [ ] Draft ADR `docs/decisions/0019-room-kind.md` updated with the advise verdict and the ASK answers before fold.
- [ ] Production, after the deploy ASK is answered: a mint with no `kind` returns `kind: "protected"` and root `t/<owner>/<room>`. A mint with `"kind":"open"` returns `~open`. Both are admitted by the live relay with `wt-session` (publish and receive). The journal over the window contains no token string. Record in `notes/prod.md`.

Handoffs are bullets in `design.md` ("Handoffs"), not boxes here.
