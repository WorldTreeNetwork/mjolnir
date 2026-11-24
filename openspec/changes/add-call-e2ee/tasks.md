# add-call-e2ee — owed work

PENDING. This revision is contract only. Review files and product code are untouched. Checkmarks below record preparation/document corrections, not acceptance of the new contract or delivery of product code. Complete harness evidence is in `spikes/complete/finding.md` and `README.md`; it does not close implementation/release boxes. `mjolnir-rurh.5` owns the shipped page experience.

## Preparation

- [x] P1. Historical room-token/path admission observation, `spikes/e2ee-path.out`. Unequal path strings do not establish label binding; old security claim is refuted and replaced by R1.
- [x] P2. Historical browser frame API test, `spikes/e2ee-js.out`. Complete real Hang media now has `spikes/complete/logs/b-chromium.log` and `b-firefox.log`; original bundle failure is historical only.
- [x] P3. Historical synthetic Node bridge test, `spikes/e2ee-iroh-live.out`; no epoch path segment was tested there. Complete label-layout native media now has `spikes/complete/logs/b-native.log`.
- [x] P4. Historical second-broadcast/finish-close test, `spikes/e2ee-rekey.out`, with out-of-band epoch; not announcement discovery proof. Complete rekey uses announcements in the new layout (`spikes/complete/logs/b-rekey-run1.log`, `b-rekey-run2.log`).
- [ ] Fresh advise after preparation
- [ ] ASK: Duke accepts epoch-in-path for `01-wip`, or chooses lite-07/upstream instance transport. Recommendation: use the tested path fallback only for this profile and revisit at the profile bump. Evidence: `spikes/e2ee-path.out`, `spikes/complete/logs/b-native.log`; design D2.
- [x] ASK: operator-served JavaScript trust boundary. Answered by Duke 2026-11-23 for this iteration, recorded in the review; non-extractable keys are only a partial mitigation. Evidence of export refusal but allowed use: `spikes/complete/logs/crypto-browsers.log`. This does not answer invite persistence or default-on profile.

## Send-back 2026-11-23

Unchanged review: `reviews/2026-11-23-advise.md` (Fable, contract `847f60d`). Checked R boxes mean the requested contract edit is present for a second review, not that the reader accepted it.

- [x] R1 (B1). D1/D2, proposal, first two requirements and ADR use label-in-context/path("call"); transplant scenario swaps both segments and aliases physical names. Evidence: 5a NO-GO / 5b GO in `spikes/complete/logs/b1-relabel.log`; regression already copied to `spikes/rust/tests/b1_relabel.rs`; original review source unchanged.
- [x] R2 (B2). D7/ADR record “not ready yet”, decided/not-landed successor at the pin, exact upstream source references, per-key limits and exhaustion behavior. Layout/ordering/manifest belong to the profile and must be re-decided at upgrade.
- [x] R3 (B3a). Encryption spec constrains content delivery only. Proposal/D3 name invite lifetime from mint, guest inability to renew and shared label on forwarded links; `mjolnir-rurh.5` owns the guest experience under room-auth. No delegated-invite change is currently named.
- [x] R4 (B3b). Replace guest-thaw requirement with per-process-instance producing state. ADR owns future VMGENID-only/observed-reseed conditions, legacy refusal and host trust boundary for guest readers and publishers.
- [x] R5 (B3c). Spec says current session-history entry, never global-history erasure; D3/proposal/ADR record both persistent-history failures and Chromium session files. C3 carries the product history check and delivery ASK; logs: `spikes/complete/logs/b3c-history-chromium.log`, `b3c-history-firefox.log`.
- [x] R6 (B3d). D5/spec pin immediate retirement after announce, read-only retention and same-session scope only for in-app credential recipients. Link guests baseline is replacement invite/rejoin; proposed paste flow and Duke's choice stay open. New-credential injection in the harness is not a delivered handoff.
- [x] R7 (B4). D6/ADR include active-relay table, no platform content-processing consequence, two-sentence SFrame/MLS alternative and accepted trusted-origin boundary. Timestamp and key-handle limitations have logs.
- [x] R8 (B5). D4/spec/ADR select one manifest JSON format for both bridges, periodic refresh and duplicate handling; catalog-only discovery is explicitly unrun. Real cross-direction evidence and H.264 native constraint are recorded; conformance edge cases stay C2/N1.
- [x] R9 (B6). D9/A1/spec/ADR name the same-crate harness relay only, no production capture or shipped runtime keylog switch.
- [x] R10. Correct all four review evidence labels in design's table and C5. New reader rule uses greatest canonical UUIDv7 with no rollback only for WIP; F2 explains why first-live-match fails, and upstream removal of ordering is recorded. No-rollback implementation/test remains C1.
- [x] R11. Proof order reconciled: complete spike now supplies real Hang wrappers with upstream Vite plugins, then native/interop/rekey under label layout. These are evidence, not product completion. C1 requires authenticated announcement discovery. Remaining product order: adapter/discovery and bridge conformance → secure credential handoff → removal/mixed media → acceptance repeat, with C5 pin checks throughout.

## Duke decisions (all remain open)

- [ ] ASK: Which profile ships on by default: WIP with label-context fix, or finished `moq-e2ee-01` after it lands and passes validation? Recommendation: WIP for development; prefer finished 01 for default-on if available after validation, otherwise ask explicitly about WIP's documented limits. Evidence: design D7, pinned upstream quest files. No upstream landing date is assumed.
- [ ] ASK: Accept navigated-invite persistence and disclose it in the page security note, or deliver the secret outside a navigated URL? Recommendation: explicit paste into an already-open page, then validate network/persistence behavior. Evidence: both history logs above; scripts run too late to stop initial history storage. Private browsing or hashchange is not a tested erasure guarantee.
- [ ] ASK: What guest lifetime beyond one token ships: accept calls ending at exp, owner-assisted replacement, higher ceiling, or scoped delegated invites? Recommendation: first release clearly states exp/remaining life and ends at exp; scope delegated renewal separately if longer calls are required, rather than silently extending the removed-member metadata window. Owner-only mint/ceiling and `spikes/complete/logs/b-expiry.log` are the basis; `mjolnir-rurh.5` owns it.
- [ ] ASK: How do remaining link guests obtain replacement credentials: per-guest rejoin or an explicit in-page handoff? Recommendation: paste a replacement per-guest invite in the open page, tested before promising same-session UX; baseline remains replacement invite/rejoin. Evidence: spike rekey injects credentials and leaves B3d handoff INCONCLUSIVE. `mjolnir-rurh.5` owns the interaction.

## Product implementation after review (not delivered by the spike)

- [ ] C1. Implement thin pinned crypto adapter, label-in-context/path("call"), canonical segment validation and room-token announcement discovery. Add regressions for both-segment transplant, malformed epoch, wrong label/profile/key, missing secret, stale first announcement and no automatic downgrade after greatest epoch ends. First-match failure is reported in complete finding F2 (the retained `spikes/complete/logs/b-rekey.log` is the later manifest diagnosis); regression B1 distinguishes expected-vulnerable and fixed tests. No plaintext fallback.
- [ ] C2. Implement both local-origin bridges with D4 manifest format. Validate metadata, complete/periodic snapshots, late audio, duplicate listings, camera toggles and teardown; no plaintext origin or stats/echo reaches relay. Complete browser proof now exists (`b-chromium.log`, `b-firefox.log`); repeat on the actual adapter. Cross-language logs validate shared shape, not every native periodic-refresh case. Require H.264 when native readers are present and keep semantic names ≤15 UTF-8 bytes.
- [ ] C3. Implement profile/fragment parsing, current URL/session-history scrubbing and non-extractable handles; no app raw-secret storage or key leakage in requests/logs/reports. Apply CSP/no third-party script/Referrer-Policy. Repeat the 60-second scan and deliberate-leak controls on product (`spikes/complete/logs/fragment.log`), inspect Chromium and Firefox persistent profiles, and implement whichever delivery/security-note choice Duke makes. Do not promise global-history erasure. Owner later-invite retention must be explicit.
- [ ] C4. Implement replacement-credential API and immediate retire-on-announce, read-only old credentials, buffered-tail handling and room-wide completion accounting. Regress against `spikes/complete/logs/b-rekey-run1.log`, `b-rekey-run2.log`; do not promise zero stall or a latency bound. Keep token reconnect and rekey distinct; preserve counters on live reconnect, mint for a new process.
- [ ] C5. Maintain both pinned shared-vector suites, browser/native relay interop and tamper tests on the actual adapter. Primitive agreement already existed in review (JS 9/205 and Rust 51); complete `spikes/complete/logs/js-unit.log` has 61 JS passes and `b-interop.log` has both primitive directions and timestamp limit. Through-relay directions are in `b5-cross-*.log`; vectors inside both browsers remain a release check. Rust repeat below is still open. Add exhaustion/duplicate-name behavior tests; preserve dependency/license provenance.
- [ ] N1. Package the native helper/bridge without a fork, conforming to the same manifest and per-instance state as browser. Real LocalBroadcast and RemoteBroadcast media proof exists in `spikes/complete/logs/b-native.log`; it is not a packaged client.
- [ ] N2. Repeat real native and both cross-direction media tests against product, including demand, late tracks, manifest refresh, teardown and codec negotiation. Complete native→browser both browsers and Chromium→native are logged in `b5-cross-*.log`; Firefox→native is open below. No fallback factory-hook architecture is selected: the real bridge now works.

## INCONCLUSIVE / unrun spike follow-ups (do not tick from current evidence)

- [ ] I1. Hand a new credential to an open page through the chosen paste/hashchange flow and capture network/persistent-history behavior. Fixture injection in rekey is not proof of delivery.
- [ ] I2. Firefox publishes H.264 to native on a fresh fixture (`cross-drive.mjs firefox <priv> 1`). Current log covers Firefox reading native only; advertised codec support is insufficient.
- [ ] I3. Firefox rekey with immediate retirement, removed reader and read-only old credential.
- [ ] I4. Firefox relay-key captures with plaintext/passive encrypted/token-only separation and content checks.
- [ ] I5. Iroh-ingress publisher expires mid-media and recovers with fresh admission. `spikes/complete/logs/b-expiry.log` times only bare Iroh close; WebTransport media tests do not fill this gap.
- [ ] I6. Repeat rekey on an idle machine, explain tail/gap versus loaded run 3 (`spikes/complete/logs/b-rekey-run3.log`); do not turn ~190 ms recovery metrics into a bound. Runs 1/2 also have watchdog records after metrics; establish a clean driver exit, not only reported playback.
- [ ] I7. Re-run upstream Rust vectors in the pinned checkout (`cargo test -p moq-e2ee`). Complete spike took the review's 51-pass result; it did not re-run it.

## Acceptance repeat against the implementation (Chromium harness evidence already exists)

- [ ] A1. Same-crate in-process harness only, keylog enabled only there; shipped binary has no runtime keylog switch. Repeat `spikes/complete/capture.sh plaintext`, decrypt/reassemble streams without filling holes and recover injected media/markers. Existing instrument proof: `spikes/complete/logs/capture-plaintext.log`, `capture-plaintext-results.json` (171 distinct VP8 frames, .995 tone ratio). Keep keys/pcaps/tokens private.
- [ ] A2. Passive encrypted capture with holders only: actual holders play media while all reassembled relay bytes have no publisher semantic markers or recognizable injected media. Existing Chromium proof: `capture-encrypted.log`/`capture-encrypted-results.json` (zero video frames/headers, .005 tone ratio). Content comparison, not decoder exit, is required: Opus accepts ciphertext as noise. Repeat with product and Firefox.
- [ ] A3. Separate token-only active capture: record all visible announcements, failed semantic probes and physical ciphertext access. Existing `capture-tokenonly.log`/`capture-tokenonly-results.json`: video probe appears ×6 in transport, zero recovered video and .007 tone ratio. Attribute probes to the requesting client rather than call them publisher leaks. Compare against passive capture and actual media controls, then repeat on product.

## Scope handoff

- No guest publisher/thaw behavior ships; the VMGENID-only future constraint is ADR 0017, including guest readers inside host trust boundary.
- No product recording/transcoding/transcription/composition of protected calls; endpoint processing with a credential is a different trust boundary.
- Guest renewal/delegation, per-guest invite UX and replacement delivery belong to `mjolnir-rurh.5` or a newly scoped change; their ASKs remain unanswered.
