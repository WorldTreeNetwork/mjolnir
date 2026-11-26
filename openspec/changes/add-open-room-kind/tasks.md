# Tasks

Revision 2 (dedicated claim). Each test below is written first and seen to fail for the stated reason before the code that makes it pass. Logs and captured runs go under `spikes/` or `notes/` in this change, with tokens redacted. No box closes on reasoning alone.

## Gate

- [ ] Fresh advise after preparation (the same Astra reader as `reviews/2026-11-25-advise.md`). No product code before an accept.

## Owner decisions (the advise's seven, in its answer order)

- [x] **ASK 1 Claim or root.** Answered by Duke on 2026-11-25: **claim**, a dedicated signed claim with a relay-first rollout; one name is one room with one kind (recorded on `mjolnir-rurh.11`). Author had recommended the root; the reviewer recommended the claim.
- [ ] **ASK 2 Mixed mints, and room lifetime and reuse.** (a) A mint that conflicts with a live room's recorded kind is refused with 409 `room_kind_conflict` and changes nothing. Author and reviewer both recommend **yes**; the orchestrator recorded it as following from ASK 1, and Duke has not confirmed it. (b) A room is live until the latest `exp` of any token minted for it. After that, the name **may take the other kind** (author's recommendation; the reviewer asked for a defined reuse policy without picking one). Alternatives: never reuse, or an explicit owner release endpoint.
- [x] **ASK 3 Marker, if roots win.** Moot after ASK 1. The withdrawn option's evidence is in `spikes/README.md`.
- [ ] **ASK 4 Mint authority.** Keep `relay:join` for an owner choosing their own room's kind; no new scope. Author and reviewer both recommend **keep `relay:join`**.
- [ ] **ASK 5 Open-room encryption.** A protected credential is accepted and used only on a protected join, in every supported client, including renewals; no plaintext fallback under a protected invitation (design D7). Author and reviewer both recommend **yes**. Binding the kind into the `call-e2ee` context is a handoff, not built here.
- [ ] **ASK 6 Enforcement.** The edge (`.13`) is the enforcement point, and the residual is accepted explicitly: a buggy edge holding a protected participant's valid token could publish plaintext into that room (design D4). Independent relay enforcement (an authenticated edge identity plus a relay policy) is not built. Author and reviewer both recommend **edge enforcement, residual accepted**.
- [ ] **ASK 7 Deployment.** Relay first (route (b) verifier), the edge with the verifier from day one, the controller next, `MJOLNIR_RELAY_OPEN_ROOMS=true` last; before any rollback, the switch goes off and the ceiling is waited out (design D5). Author and reviewer both recommend **this order** (the reviewer: "relay/readers first for the claim choice, with open issuance last and rollback fenced").
- [ ] **ASK 8 (author) How the relay reads the claim.** Route (b): the relay verifies room-token signatures itself and hands moq-auth's strict decoder the payload without `kind`, rather than (c), a carried moq-auth patch. Recommendation: **(b)**, because it carries no patch, adds no crate and leaves the moq pin alone. Its cost is a Mjolnir-owned signature step, held to parity by the corpus test below. Fallback (c) is described in `notes/claim-option.md`.

## Hypotheses (before act)

- [ ] H-parity: a differential test in `native/mjolnir_relay` replays every token case in moq-auth's `rs/moq-auth/tests/corpus.json` (at `4a6f522`, read from the cargo checkout or copied with provenance) that has no `kind`, through `room_token::verify` and through `KeySet::verify`, with a kio `Manual` clock installed on the runtime at the corpus's time. Every disagreement is listed. Each one must be a stricter refusal by route (b) (expected: a kid-less token against a single kid-less key); any looser acceptance blocks act. Red first: the test fails to compile until `room_token` exists.
- [ ] H-iroh: on the harness relay (`spikes/rust`, `relay-claim` extended with the Iroh mount), `iroh-publish`/`iroh-subscribe` rebuilt from current source publish and receive with an open token through route (b), and the production `TokenPolicy` refuses the same token. Log `spikes/logs/claim-iroh.log`.
- [ ] H-chromium: a harness page built from the pinned JS tree (`@moq/net`, `serverCertificateHashes` from the harness's 10-day ECDSA certificate) and a Playwright Chromium driver. With an open token, the page publishes and a second page reads frames through the route (b) relay; the production decider refuses the same token. Log `spikes/logs/claim-chromium.log`.

## Relay (`native/mjolnir_relay`)

- [ ] `room_token::verify(set, token) -> Result<(Claims, RoomKind), Refuse>` as design D1 steps 1–6, with `assess` returning the kind and `web_grant` and `TokenPolicy` unchanged otherwise. Red first: `tests/room_kind.rs` replays a committed fixture file (`tests/fixtures/room-kind.json`: the 19 cases of `spikes/logs/claim-offline.log`, minted by `spikes/claim/mint_fixtures.exs` with a dummy key at `iat` 1735689600) under a kio `Manual` clock installed on the test runtime, and asserts the route (b) column of that log. It fails to compile, then fails per case, until implemented. Existing relay tests pass unmodified.
- [ ] Time controlled through the whole verification: the same test steps the installed clock to `exp − 1` (admit) and `exp` (refuse), for an open and for a pre-change token. Red first.
- [ ] Token minted before this change: at the parent commit of the mint change, run today's `Mint.issue` for a fixed owner with a test key, and save the token and public key as `tests/fixtures/mint-pre-kind.json`. The relay test admits it at a manual time inside its life and reports `Protected`. Red first: fails to compile until `RoomKind` exists.
- [ ] The production verifier's refusal, kept as a test: `legacy_keyset_verify_refuses_kind` calls `KeySet::verify` (what `ca61ceb` runs) on the open and explicit-protected fixtures and asserts refusal, and admission of the claim-free fixture. It passes on today's code (record that it passed first), and it documents why open issuance waits for the relay.
- [ ] `room_token` is public for the edge (`.13`). The doc comment names the corpus test as the parity guard.

## Mint and room record (Elixir)

- [ ] `mint_test.exs` "open kind carries the claim": with `MJOLNIR_RELAY_OPEN_ROOMS=true`, body `%{"kind" => "open"}` gives root `t/<owner>/standup`, claim names the six of today plus `kind`, `kind` `"open"`, response `kind: "open"`. Red first.
- [ ] `mint_test.exs` "protected carries no claim": no body and `%{"kind" => "protected"}` give exactly today's six claim names and response `kind: "protected"`. The existing first test passes **unmodified** except for one added `kind` assertion. Red first: the `kind` key is missing.
- [ ] `mint_test.exs` "bad kind is 400 before env": `"Open"`, `"open "`, `""`, `nil`, `1`, `true`, `["open"]`, `%{}` each give `{:error, 400, "bad_kind"}` with a valid env and again with the env file deleted. Red first.
- [ ] `mint_test.exs` "open switch": without the env line, `kind` open is `{:error, 503, "open_rooms_unavailable"}`, with no record file created; protected still mints. Red first.
- [ ] `mint_test.exs` log: `capture_log` shows `kind=open` or `kind=protected` only. A rejected raw value (`"OPEN-zz9"`) never appears in the log. The token never appears. Red first.
- [ ] Router test (`test/mjolnir/api/relay_mint_router_test.exs`): the conflicting body/header/query matrix of the "Kind outside the body" scenario, through the real auth plug as the existing tests do. Each response's `kind` and each token's claims follow the body only. `Cache-Control: no-store`. Red first: the `kind` key is absent.
- [ ] `Mjolnir.Relay.RoomKinds` tests (`test/mjolnir/relay/room_kinds_test.exs`, `async: false`, store directory from config `:relay_rooms_dir`): first mint creates a `0600` file in a `0700` directory, named by the lowercase hex of the room name; a conflict is 409 with the file byte-identical and nothing signed; a same-kind renewal raises `last_exp`; 50 concurrent pairs of open and protected first mints for 50 rooms give exactly one record each, with each loser 409; the record survives `stop`/`start` of the process; an unparseable file is 503; a read-only directory (a write failure) is 503 with nothing signed; reuse after `last_exp` follows ASK 2 (b). Red first: the module does not exist.
- [ ] Mint wiring: the record decision runs after the key check and before signing (the order test: with a missing key, no record is written). Red first.
- [ ] Old-controller fixture for the rollback rule: before any mint code changes, run today's `Mint.issue` with body `%{"kind" => "open"}` and save the response shape (no `kind` key) and the decoded claim names (no `kind`) as `test/fixtures/relay/old-controller-open.json`. This test passes first, by design, and is recorded as the observation that the old controller silently ignores `kind`. The `.15`/`.5` client tests consume the fixture (handoff).

## Operations and docs

- [ ] `docs/runbooks/edge-relay.md`: the switch line, when to set it (after an open token is admitted by the live relay), and the rollback fence (unset, wait out the ceiling). `deploy.sh` never sets it.
- [ ] Backup: `/var/lib/mjolnir/relay-rooms` added to the B2 backup sources, with the script change shown by a dry run listing that path.
- [ ] `CLAUDE.md` relay line: the body `kind`, the switch, the room store path, and 409 `room_kind_conflict`.
- [ ] ADR `docs/decisions/0019-room-kind.md` updated with the advise verdict and the ASK answers before fold.

## Production (owner gates; no production access in design)

- [ ] **Owner gate** Relay redeploy with route (b): `./scripts/deploy.sh root@45.76.77.97 --relay` (restart, drain `MJOLNIR_RELAY_DRAIN_SECONDS`). Before and after: a room test with today's minted tokens passes on WebTransport and Iroh. Open tokens are first tried on production only after the controller deploy and the switch (no test key is ever added to the production key set). Notes in `notes/prod.md`.
- [ ] **Owner gate** Controller deploy (`--app-only`, hot cutover): a mint with no `kind` is unchanged apart from response `kind: "protected"`; a mint with `"kind":"open"` is 503 `open_rooms_unavailable`; `/var/lib/mjolnir/relay-rooms` is `0700 root`.
- [ ] **Owner gate** Switch on: `MJOLNIR_RELAY_OPEN_ROOMS=true`. An open mint is admitted by the live relay on WebTransport (`wt-session` publish and read); a protected mint for the same room is 409; the journal over the window contains no token.

Handoffs (to `.13`, `.15`, `.5`, `.14`, `.4`, `add-turn-service`, `add-call-e2ee`) are bullets in `design.md`, not boxes here.
