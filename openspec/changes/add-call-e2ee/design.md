# add-call-e2ee — design

PENDING contract revision, 2026-11-24. Addresses B1–B6 of `reviews/2026-11-23-advise.md`; that review is unchanged. No product implementation is authorized. The complete disposable spike is `spikes/complete/finding.md`; commands and toolchain are in `spikes/complete/README.md`. Evidence below means the logged harness result, not a shipped client or a new run in this revision.

## Evidence and corrected labels

All complete runs below use moq `4a6f522483168ace392718d68b58a402533c897d`, iroh-live `747b1bd0567d2f6b019a89633c04e6561ccac460`, room-token admission, default moq-lite-06 and the label-in-context layout unless explicitly marked old. Log paths are relative to this change.

| Observation | Verdict and exact scope | Evidence under `spikes/` |
|---|---|---|
| Original path spike | Admission and unequal path strings only; it did not try a two-segment transplant | `e2ee-path.out` |
| B1 old layout, claim 5a | NO-GO: relay swaps label AND opaque; victim decrypts alice as bob | `complete/logs/b1-relabel.log`, regression `rust/tests/b1_relabel.rs::relay_relabel_passes_d2_checks` (passes when vulnerable) |
| B1 label context, claim 5b | GO: same transplant, even aliasing physical names, returns Authentication | `complete/logs/b1-relabel.log`, `label_in_context_refuses_the_relabel` |
| Original rekey | Second broadcast on same sessions and finish/close only; used path("call"), route instance and out-of-band epoch, not D2 discovery | `e2ee-rekey.out` |
| Original native path | Synthetic Node bridge only, no epoch path segment; epoch-in-path test was WebTransport only | `e2ee-iroh-live.out`, `e2ee-path.out` |
| Real Hang browser media | GO: Chromium 158 and Firefox 159, announced path discovery, decoded video and audio, label context | `complete/logs/b-chromium.log`, `complete/logs/b-firefox.log` |
| Real native media | GO: LocalBroadcast H.264/Opus, Iroh ingress, WebTransport reader, RemoteBroadcast decode, epoch in path, no fork | `complete/logs/b-native.log` |
| Cross-language | GO: primitives, payload/group/name/key/label tamper refusals; timestamp mutation still decrypts. Through-relay native→browser both browsers; browser→native Chromium only | `complete/logs/b-interop.log`, `complete/logs/b5-cross-chromium.log`, `complete/logs/b5-cross-firefox.log` |
| Vectors | Primitive agreement already held: review ran JS 9 tests/205 assertions and Rust 51 tests (`reviews/2026-11-23-upstream-vectors.out`), not “no cross-language agreement”. Complete run adds JS vectors/layout validation, 61 pass; Rust not re-run there | `complete/logs/js-unit.log`; Rust repeat remains owed |
| Rekey in real layout | GO with buffered tails: new credential injected into page, announce discovery; immediate retirement gives ~190 ms stall then recovery in clean runs | `complete/logs/b-rekey-run1.log`, `b-rekey-run2.log`; loaded run `b-rekey-run3.log` not a latency guarantee |
| Expiry | WebTransport reader/publisher mid-media expiry and reconnect; bare Iroh close only | `complete/logs/b-expiry.log` |
| Fragment requests and keys | Chromium 60 s network scan, deliberate leak control 3/3; both browsers reject export but permit same-origin key use | `complete/logs/fragment.log`, `complete/logs/crypto-browsers.log` |
| Persistent history | NO-GO for erasure: invite URL, key, token persist in both browsers; Chromium session files also retain them | `complete/logs/b3c-history-chromium.log`, `complete/logs/b3c-history-firefox.log` |
| Relay-key capture | GO in Chromium harness: plaintext content recovered; passive encrypted capture has no semantic markers/content; separate token-only capture reveals its own semantic probes | `complete/logs/capture-{plaintext,encrypted,tokenonly}.log` and corresponding `-results.json` |

The original JS fixtures in `spikes/js/` used public/no-auth relay and query-string dummy keys. They are historical API probes, superseded for integration evidence by `spikes/complete/`. Neither a passing harness nor this contract completes product implementation boxes.

## Decisions

### D1. Separate admission and content; put the label in the context

Room tokens authorize relay sessions and publish labels under `relay-room-auth`; their issuance, delivery and expiry are not encryption requirements. The mint, token claims and deployed relay remain unchanged. Content uses client-generated `{profile, kid, secret}`, with 32 random secret bytes; every holder derives a separate `Credential` for each publisher label using context **`mjolnir-call/v1/<owner>/<room>/<label>`**. It shares the room secret and kid, not a room-wide context. Opaque is **`credential.path("call")`**. A subscriber constructs the credential from the announced label, never the sender-supplied context.

The relay and host processes never receive usable key material; derived opaque paths, physical names and ciphertext necessarily reach them. The origin serving browser code is trusted for this iteration (Duke accepted 2026-11-23). Deriving the secret from a room token or server secret would give the operator content access and is rejected.

B1 is a correction, not an alternative still offered: the old room-context/path(label) layout does not bind payload keys to the label. Claim 5a demonstrates the attack; claim 5b rejects it with label context (`spikes/complete/logs/b1-relabel.log`). A holder cannot publish under another label if relay grants are enforced; a relay without the secret cannot move ciphertext across label contexts. A relay colluding with a credential holder can impersonate; holders are not cryptographically authenticated against one another.

### D2. Profile-specific path and reader instance rule

For **`moq-e2ee-01-wip` only**, the full path is `t/<owner>/<room>/<label>/<opaque>/<epoch>`, WebTransport relative spelling `<label>/<opaque>/<epoch>`, Iroh absolute spelling. Opaque is 22 base64url characters from D1's label credential and path("call"); epoch is canonical UUIDv7 from `credential.produce()`, never caller-selected for encryption. The owner chooses a random participant label when minting a guest token; the browser client should also choose a random room id. Display names stay encrypted.

The subscriber validates all segments, derives that label's credential, checks opaque, and consumes the epoch from the path. **Among active valid announcements for one credential and label, select the greatest canonical UUIDv7 epoch; retain the greatest observed value as a high-water mark and never automatically downgrade to an older epoch when the selected one disappears.** Follow a greater epoch when announced; otherwise wait/report unavailable. This pins the earlier greatest-epoch proposal to this profile. Its high-water behavior still needs a product regression test; it is not claimed as measured.

Reason: all broadcasts under one credential/label share an opaque. The first-live-match rule selected an old broadcast from a killed run whose session was still alive (complete finding F2; the retained `spikes/complete/logs/b-rekey.log` records the later manifest diagnosis, not the earlier stale-path mismatch). Sorting by announcement arrival is also vulnerable to initial listing order. UUID ordering gives a deterministic preference at this pin, not authenticated freshness or a guarantee about clock order. A relay can hide the newer epoch, replay an old one to a fresh reader, or deny service; the rule does not solve those powers.

The default wire loses the upstream route Instance (`spikes/e2ee-path.out`); iroh-live cannot supply it at its pin. Epoch-in-path now has native media evidence too (`spikes/complete/logs/b-native.log`), rather than the old inference from a WebTransport test. Alternative A requires every peer and relay to opt into lite-07 plus an iroh-live instance hook; alternative C needs an authenticated application channel absent for guests. Recommend the path fallback at this pin; Duke's existing epoch-layout ASK remains open. The layout belongs to the profile named in the invite. Upstream's successor deletes UUIDv7 epoch ordering: at a `moq-e2ee-01` bump this rule and path must be decided again, not silently carried forward.

### D3. Link delivery and the accepted browser boundary

Content invite fields are `#v=1&p=moq-e2ee-01-wip&kid=<u53>&k=<43 base64url characters>`. Context is derived as D1, not delivered by the link. The call page may also receive an independently issued room token; if a token is delivered in a link it goes only to relay admission, never other page requests, logs or reports. Encryption does not require co-delivery or prescribe its format.

The page reads the fragment, checks the 32-byte length, imports the secret to a non-extractable HKDF CryptoKey, passes only the handle to the library, and replaces the current URL using `history.replaceState`. This removes the fragment from the address bar and **current session-history entry only**. Do not retain raw bytes in application storage or error reporting; parser strings cannot be reliably wiped. An owner making later links must retain secret/link material or create invitations up front, so a handle-only guest model is not an owner guarantee. Serve no third-party scripts, Referrer-Policy no-referrer and a CSP limiting scripts and connection origins. The content key must never reach mint requests; token admission and opaque protocol data are explicit network exceptions, not exceptions for the secret.

**Navigated-link limit:** Chromium and Firefox write the full initial invite URL, key and token to persistent history before page script runs; Chromium also retains them in session files. replaceState cannot prevent or erase this (`spikes/complete/logs/b3c-history-{chromium,firefox}.log`). No claim is made about unscanned compressed Firefox session storage. Duke must accept this limit with a page security note, or choose secret delivery other than a navigated URL. Paste into an open page is recommended; same-document hash navigation is untested and must not be described as avoiding persistence.

Duke already accepted that the page origin is trusted (2026-11-23). Non-extractable keys are a partial mitigation: both browsers reject export but a script holding the HKDF handle derives raw media keys and decrypts (`spikes/complete/logs/crypto-browsers.log`). They stop export, not use or access to plaintext, and cannot defend against replaced origin code.

Admission limits owned by `mjolnir-rurh.5` and existing `relay-room-auth`, not this encryption capability:

1. A link's token expires at its fixed exp, normally at most 3600 s after mint, not after opening (ceiling is operator-configurable).
2. A link guest cannot renew: only the owner can mint this room's tokens. Calls end at exp; owner refresh/reconnect or future delegated invites are separate work, with no delegated-invite change currently named here.
3. One link carries one publish label. Forwarding it shares that label; the reader instance rule selects one stream, not two people. The owner must issue per-guest links.

### D4. Both bridges use one protected manifest surface

Choose the **manifest model demonstrated by the complete spike**, rather than the review's preferred catalog-only model. Both browser and native bridges carry every local semantic track, catalog representations included, plus protected **`bridge.tracks`**, all under D2's broadcast. Each manifest group has one JSON frame:

`{"<semantic>": {"timescale": <units/s or null>, "maxAgeMs": <number or null>, "priority": <i8>}}`

It is a complete current track snapshot, encrypted like any track. Publish an updated snapshot when the track set changes and refresh every second while live, so late readers and rekey do not depend on a single cached snapshot. Readers obtain semantic names from this manifest and derive physical names with their consuming generation; they do not hardcode browser or native track names. Metadata must agree with physical TRACK_INFO; native readers may use TRACK_INFO. Skip duplicate listed names within a generation instead of creating the same protected track twice. Keep track handles across camera toggles, or mint a new generation when a fresh producer is required.

Evidence: the first bridge died on JS `Failure: reuse` after re-listing; an early manifest missed audio. Duplicate suppression and periodic refresh fixed the harness (`spikes/complete/logs/b-rekey.log`, finding F3). Both directions work with the shared JSON shape (`spikes/complete/logs/b5-cross-{chromium,firefox}.log`); that does not separately establish every native periodic-refresh edge case, which remains a bridge conformance test. The catalog-only/no-extra-track model is **unrun**; adopting it now would discard the tested discovery mechanism. This manifest is an application wire commitment for this profile, to revisit when upstream trait wrappers remove the bridges.

Native Node::publish_with wraps LocalBroadcast's local, never network-connected plaintext origin. Decryption mirrors into another local origin for RemoteBroadcast/Watch. Groups, timestamps and payloads pass through the bridge; names and catalogs reach the relay encrypted. No fork is needed at these pins (`spikes/complete/logs/b-native.log`). Browser must publish **H.264 when a native reader is present**: native player supports H.264, not the default browser VP8. Chromium publishing H.264 to native is logged; Firefox publishing H.264 to native is unrun despite advertised codec support. Browser reading native H.264 succeeds in both logs. Disable plaintext stats/echo and never attach a plaintext origin to a session.

### D5. Removal, distribution and immediate retirement

The owner generates a greater kid and fresh secret, and distributes it only to remaining members. This change guarantees same-session switching only for clients **already supplied** the replacement credential through an in-app API. For link guests the baseline is a new per-guest replacement invite and rejoin; delivery into an open page is not demonstrated. Recommend an explicit paste-replacement-invite action in `mjolnir-rurh.5` so a guest can adopt it on the same session, pending Duke's choice and a network/history test. The rekey harness injects the credential directly, not by paste or hashchange.

On adopting it, each publisher creates and announces a new producing generation, then **immediately stops encrypting under the previous credential, finishes its tracks and closes the old broadcast**. Do not wait for reader acknowledgements. Withdrawal alone does not stop existing readers. Remaining readers MAY keep the old credential **read-only** until old broadcasts end while following the new one; this never authorizes more old-key publication.

Chromium runs 1/2 recorded recovery with ~190 ms of no new frame when old publication retired immediately (`spikes/complete/logs/b-rekey-run1.log`, `b-rekey-run2.log`). Leaving it up fed removed readers another 34–46 frames; buffers continued for ~0.5–0.7 s after retirement. Runs 1/2 also end with a 90-second watchdog record after those recovery metrics; they do not demonstrate a clean driver exit. These are observations, not timing guarantees. Loaded run 3 had a 5 s tail/watchdog; idle rerun and Firefox rekey remain owed. Removal across the room is only complete when the slowest remaining publisher receives the replacement and retires old publication. An offline/missed publisher keeps feeding the removed member; the UI must not declare completion without accounting for it.

A removed member retains old recordings and credentials, announcements and metadata access until token exp. A token-only client sees label/opaque/epoch and can fetch ciphertext if given physical names (the relay learns them from subscriptions); failing semantic-name requests is not denial of physical access (`spikes/complete/logs/capture-tokenonly.log`). It cannot decrypt new content. Token expiry ends the session: WebTransport publisher and reader media stop, bare Iroh enters Reconnecting; fresh owner tokens can resume with the same live generation/counters (`spikes/complete/logs/b-expiry.log`). Reconnect is not rekey; never reset counters under an existing generation. Iroh publisher mid-media expiry is still unrun; link guests cannot renew themselves.

### D6. Confidentiality and active-relay capabilities

Semantic track names at most 15 UTF-8 bytes share a padded physical-name length class (59 base64url characters). Catalogs, manifest and display names are protected tracks. Labels/room/owner, opaque/epoch, physical names, track counts/kinds, group/frame structure, public timestamps, sizes and timing remain visible; there is no traffic-analysis protection. Frame timestamps are **not authenticated**: 124→999 ms still decrypts (`spikes/complete/logs/b-interop.log`).

| Active relay capability | Limit / basis |
|---|---|
| Drop, delay, reorder; truncate a group after any frame | No completeness/liveness guarantee; pinned draft §Security Considerations, lines 329, 372–373 |
| Replay earlier ciphertext of the same producing instance to a new/late reader | No authenticated freshness; draft line 329 |
| Shift timestamps | Public metadata not AEAD-bound; `spikes/complete/logs/b-interop.log` |
| Hide a newer instance/credential or replay stale announcements | D2 cannot force disclosure; draft line 148, spike F2 |
| Spend a consuming key's budget through failed opens | WIP limits include failed attempts; upstream `quest/m3/e2ee-format.md:64-70` |
| Fetch/serve physical ciphertext to a token-only client | `spikes/complete/logs/capture-tokenonly.log` |
| Re-label to another context without a holder's secret | Rejected with Authentication after D1 fix; `spikes/complete/logs/b1-relabel.log` |
| Read/forge payload or splice across context/kid/epoch/semantic track/group/frame identity | AEAD boundary; tested tamper cases in `spikes/complete/logs/b-interop.log`; no protection against a colluding credential holder |

Permanent product consequence: the platform cannot record, transcode, transcribe, compose or preview protected calls while it lacks the credential. Only a credential-holding endpoint can perform those operations; putting one in a Mjolnir guest places its credential inside the host trust boundary. Content encryption permits future untrusted fan-out, but this change delivers no peer bandwidth savings: the relay still serves central egress.

Not chosen: SFrame with MLS would provide forward secrecy, post-compromise recovery and membership removal, but requires member identity keys and a delivery service with no implementation at this pin. A future MLS exporter could supply `{kid, secret}` per MLS epoch through the credential seam; this revision does not implement or claim those group-security properties.

### D7. Upstream is not ready yet; keep the adapter thin

At pinned moq `4a6f52248`, upstream explicitly says **“not ready yet”**, with `moq-e2ee-01` decided 2026-11-16 and not landed in that tree (`quest/m5/e2ee/README.md:11`; `rs/moq-e2ee/Cargo.toml:13` links the format work). The review's 2026-11-24 upstream check also found it not landed; this revision makes no new claim about current remote main.

`quest/m3/e2ee-format.md:25-49,54-82,109-130` decides: bind semantic broadcast name natively via produce/consume; one key per group replacing per-track exhaustion budgets; public per-track wrapper and moq-net trait-compatible wrappers; Epoch becomes moq_net::Instance, deleting UUIDv7 ordering; no compression in the profile. `quest/m5/e2ee/README.md:38-39` closes/supersedes the upstream mux bridge; `quest/m5/e2ee/browser.md:11` plans native encrypted-broadcast integration in publish/watch. These are plans at this pin, not APIs we may assume available.

Until then each track key is capped at **2^36 plaintext bytes or 2^24 operations**, failed opens included. On producer Exhausted, stop old encryption and mint/announce a new generation without resetting claims. A subscriber may rebind the same epoch to a new consuming handle/budget with bounded retry and visible failure under repeated exhaustion; this grants no producing rights. Never silently drop encryption to recover. JS refuses duplicate track creation; Rust resumes claims, so bridge behavior must respect the stricter side.

Keep Mjolnir's surface to a crypto adapter, profile-specific layout/manifest, and invite parsing. Pin both languages and vectors together. The link names the profile; reject unsupported profiles explicitly, no plaintext fallback. A profile bump changes keys/names/paths and is a coordinated client upgrade; it changes neither relay nor admission. Re-decide the D2 ordering/layout and D4 manifest at the bump. Duke still chooses which profile ships on by default; recommend `01-wip` only as a development target, and prefer finished `01` for default-on if available after validation. Do not guess his answer.

### D8. Per-process-instance uniqueness

Every new publisher process instance calls produce() to mint its generation. Live reconnects may retain that generation only while all original nonce/claim state remains intact; do not serialize/recreate a producing generation. This change ships browser/native process clients, not guest snapshot support. Future guest constraints, including VMGENID/legacy-capture conditions, are in ADR 0017 rather than an unimplemented requirement here.

### D9. Acceptance uses a harness relay, never a production keylog

The relay is the **in-process harness built from the same mjolnir-relay crate**, using its admission decider and Iroh handler. Only the harness enables moq-tokio quic.keylog, as `spikes/complete/README.md` describes. No capture runs on production and the shipped binary gets **no runtime keylog switch**.

Use `spikes/complete/capture.sh`: tshark 4.4.0 captures the harness listener on lo0, decrypts with harness session keys, reassembles STREAM bytes per connection/stream without filling holes, and compares to publisher-local reference payloads. Keep pcaps, tokens and keys private. An opaque/empty capture fails instrumentation.

Separate three captures: plaintext control, passive encrypted call with holders only, and active token-only semantic probes/physical reads. Check content: VP8 headers and distinct decoded frames, injected catalog/display/name markers, content-key encodings, and the injected 440 Hz tone ratio in decoded Opus. **Decoder exit status is insufficient: Opus accepts ciphertext as noise.** Passive encrypted capture must have no publisher semantic markers or recognizable injected media while holders render/hear it. Negative semantic requests themselves appear in decrypted transport; token-only capture's `video` ×6 is its own probe, not a publisher leak.

The logs and results JSON show plaintext 171 distinct VP8 frames/tone ratio .995, encrypted zero frames/headers and .005 tone ratio, token-only zero video and .007 tone ratio (`spikes/complete/logs/capture-{plaintext,encrypted,tokenonly}-results.json`). This is Chromium harness evidence, not Firefox capture or a production acceptance run. Repeat against the shipped adapter before shipping; compare content metrics with positive controls rather than requiring every decoder to error.

## Remaining unverified hypotheses / decisions

- Handing a replacement credential to an open page: INCONCLUSIVE, fixture injects it. `mjolnir-rurh.5` owns the paste/rejoin choice and secure flow; `tasks.md` keeps it open.
- Firefox H.264→native, rekey and capture: unrun; browser/native API support is not enough.
- Iroh-ingress publisher expiring mid-media: unrun; bare link close is narrower evidence.
- Idle-machine rekey: rerun to distinguish loaded harness starvation from relay buffering; no fixed latency guarantee.
- Rust upstream vectors: review's 51-pass result remains valid historical evidence, but complete spike did not re-run them.
- ASK: default-on profile; navigated invite/history limit; guest lifetime beyond one token; replacement credential delivery; existing epoch-in-path approval. Recommendations are in tasks; none is answered here.
