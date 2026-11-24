# add-call-e2ee — owed work

The contract is PENDING. This pass prepares spikes and a contract only; product implementation waits for Fable advise and activation. Evidence below is the failing observation or regression each task must change. Checks belong to this change; the shipped call-page work is coordinated with `mjolnir-rurh.5`.

## Preparation

- [x] P1. Prove label-bound opaque and epoch-in-path admission with unchanged room claims. Evidence: `spikes/e2ee-path.out`, `tests/e2ee_path.rs`; default wire loses the route epoch, but the path variant decrypts. Fresh suite: `spikes/rust-verify.out` (four tests).
- [x] P2. Run browser frame crypto in Chromium and Firefox. Evidence: `spikes/e2ee-js.out`; catalog and three frames decrypt, tokenless fixture reader sees no plaintext, wrong-secret read fails. This is not Hang component or fragment proof.
- [x] P3. Test native Node publishing without a fork. Evidence: `spikes/e2ee-iroh-live.out`; synthetic local frames cross the bridge and Iroh and decrypt at a WebTransport reader. Real encoder/player remain N2.
- [x] P4. Test removal. Evidence: `spikes/e2ee-rekey.out`; withdraw-only fails (51 more old frames); finish/close passes and bob switches on the same sessions.
- [ ] Fresh advise after preparation
- [ ] ASK: Duke accepts D2's epoch-in-path departure from draft-01, or chooses the lite-07/upstream path. Evidence: `spikes/e2ee-path.out` shows the default wire loses Instance epoch; D2 compares options.
- [ ] ASK: Duke accepts operator-served JavaScript as the web E2EE code-integrity trust boundary, or selects a pinned/native distribution. Evidence: no shipped page yet; design D3 identifies the fragment-reading code's authority.

## Implementation after review

- [ ] C1. Implement pinned browser crypto adapter and generation/path validation. Regression: current plaintext Hang components do not wrap tracks; `e2ee-page.ts` is fixture-only. Test changed label, malformed epoch, unsupported profile, missing/wrong key, and newer announcement selection; no plaintext fallback.
- [ ] C2. Integrate Hang publish/watch through a local plaintext origin and encrypted bridge, including audio. Failure: `spikes/e2ee-js-components.out` cannot bundle worklet/CSS imports. Use upstream Vite plugins; in Chromium and Firefox 153+ record moving decoded video and audible/decoded injected audio through the protected relay. Record track names and reject names over 15 UTF-8 bytes. Do not expose a local plaintext origin to a session.
- [ ] C3. Add fragment parsing/removal and key confinement in the shipped page. Regression: current JS fixture sends dummy keys in query strings. Capture a one-minute join's page requests, relay admission, mint request and logs; assert no secret in raw/base64url/hex encodings, token only at intended relay admission, mint body at most ttl, fragment absent after replaceState; a deliberate leaked fixture must fail. Check CSP, no third-party scripts and Referrer-Policy.
- [ ] C4. Implement rekey with retirement and resubscribe on existing sessions. Regression: withdraw-only failure in `spikes/e2ee-rekey.out`. Assert removed reader ends after bounded buffered frames, remaining reader switches, missed/old credentials cannot silently continue plaintext, and expired room tokens still disconnect on both transports. Content retirement and token expiry are separate events.
- [ ] C5. Run upstream vectors in Rust and JS plus cross-language frame/name interop at the pin; negative authentication/tamper cases must fail. Regression: separate Rust and JS fixture runs currently prove no cross-language agreement. Keep source/dependency pin and license notices reproducible.
- [ ] N1. Package the native helper and bridge without a fork. Regression: only spike-local helper exists; real client has no crypto integration.
- [ ] N2. Run real iroh-live LocalBroadcast encoder and native player through encryption/decryption, including demand signals and catalog. Gap: `spikes/e2ee-iroh-live.out` uses synthetic local frames. If it fails, test upstream factory hook per D4 and return the contract for review before choosing it.

## Acceptance (not run in this contract pass)

- [ ] A1. Validate relay-key capture instrumentation with plaintext positive control: relay `quic.keylog`, tshark UDP listener capture, `tshark -o tls.keylog_file:<keylog> -r <pcap>`, reassemble/extract MoQ streams/datagrams. Assert nonempty decoded transport data and recover the known media marker, semantic names, display name and playable media. Evidence gap: no pcap exists; opaque bytes alone are not proof. Method: design D9 and “Acceptance capture method and limits”.
- [ ] A2. Repeat protected two-client real audio/video call with same capture method. Both holders see/hear; transport-decrypted relay bytes reveal opaque routes and physical names, contain none of the injected plaintext/catalog/name markers, and cannot decode as media. Evidence gap: current spikes use marker frames, not a relay-key capture with real media. Save commands, tool versions, extraction counts and decoder outcomes in `evidence/relay-capture.out`; keep keys/pcaps private.
- [ ] A3. Record valid-room-token/no-content-key third client and all-room relay-side tap. Regression: current Rust tap gets ciphertext but has not attempted real-media playback. Fetch known physical tracks, record ciphertext, fail to decode, and verify semantic-name subscriptions fail. Compare tap bytes with A2's extracted bytes.

## Handoffs and scope

- Guest publisher clone/thaw generation remint is a requirement for a future guest publisher change; none is shipped here, so no unclosable guest task is claimed.
- Resubscribe across token refresh and the call page's invite/remove controls are coordinated with `mjolnir-rurh.5`; this change owns the crypto behavior and its acceptance.
- The stale room-auth references requested in the assignment were already corrected during its fold. Both archived files now point at the edge-relay living spec; no archive rewrite is needed.
