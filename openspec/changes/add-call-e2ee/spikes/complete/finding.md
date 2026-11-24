---
spike_id: complete-call-e2ee
run_at: 2026-11-24T06:33:00Z (started); finished 2026-11-24 (PST night of 2026-11-23)
verdict: mixed — GO for the mechanism on the label-in-context layout; NO-GO for D2 as written and for "removed from history"
version-pinned: moq@4a6f522483168ace392718d68b58a402533c897d, iroh-live@747b1bd0567d2f6b019a89633c04e6561ccac460
tracking: mjolnir-rurh.9.1
---

# Complete call E2EE spike: finding

Baseline main `847f60d`. Disposable harness only: a real `moq-relay` started in-process from
`spikes/rust` with the Mjolnir WebTransport decider and Iroh session handler, and room tokens shaped
like the ones `Mjolnir.Relay.Mint` signs. No product code, no production host. Browsers: Chromium
158.0.8127.18 (headless shell), Chromium 159.0.8154.6 (full build, history check only), Firefox 159.0.
Default wire `moq-lite-06`. Profile `moq-e2ee-01-wip`, AES-128-GCM under HKDF-SHA-256.

**Read this first.** The browser, native and interop runs that the interrupted agent logged
(`chromium.log`, `firefox.log`, `native.log`, `interop.log`, `rekey-real.log`) used the contract's
current D2 layout: one context per room (`mjolnir-call/v1/<owner>/<room>`) and opaque = `path(<label>)`.
That is what "label-bound opaque" meant in the earlier draft. That layout is vulnerable (claim 5). Every
claim below was re-run on the review's B1 fix instead: **context `mjolnir-call/v1/<owner>/<room>/<label>`,
opaque = `path("call")`** ("label layout"). The harness keeps both (`ctx=room` reproduces the old one).

Logs referenced as `logs/…` are from this session; bare `*.log` in this directory are the earlier
agent's and are kept as found. Reproduce everything with `run-all.sh` (see `README.md`).

## Verdicts

| # | Claim | Verdict | Evidence | Who ran it |
|---|---|---|---|---|
| 1 | Browsers play real Hang media, encrypted, through an authenticated relay, epoch from the announcement path | GO (label layout) | `logs/b-chromium.log`, `logs/b-firefox.log` | re-ran (twice) |
| 2 | Native iroh-live `LocalBroadcast` H.264 + Opus, Iroh ingress, WebTransport egress, decrypt + decode, no fork | GO (label layout) | `logs/b-native.log` | re-ran |
| 3 | Rust↔JS interop both ways; tamper cases fail; timestamp not authenticated | GO, with limit L1 | `logs/b-interop.log` | re-ran |
| 4a | Plaintext capture control recovers media with relay keys | GO | `logs/capture-plaintext.log`, `logs/capture-plaintext-results.json` | re-ran (twice) |
| 4b | Passive encrypted capture, credential holders only: zero media, zero semantic markers | GO | `logs/capture-encrypted.log`, `logs/capture-encrypted-results.json` | re-ran (twice) |
| 4c | Token-without-credential client, separate capture | GO (decodes nothing); see what it reveals | `logs/capture-tokenonly.log`, `logs/capture-tokenonly-results.json` | re-ran (twice) |
| 5a | D2 as written stops a relay re-labelling alice as bob | **NO-GO** (attack succeeds) | `logs/b1-relabel.log`, `rust/tests/b1_relabel.rs` | re-ran |
| 5b | Label in the credential context stops it | GO | same | re-ran |
| 6 | Removal by rekey in the real layout (announce discovery, room tokens, epoch in path) | GO, with findings F2, F3 | `logs/b-rekey-run1.log`, `run2`, `run3`; `logs/b-rekey.log` (bug diagnosis) | re-ran |
| 7 | Token `exp` mid-call: what happens, what the client must do | GO (behaviour pinned) | `logs/b-expiry.log` | new |
| 8 | B5 wire surface: browser reads native, native reads browser | GO both directions, with deviations D2–D4 | `logs/b5-cross-chromium.log`, `logs/b5-cross-firefox.log` | new |
| 9 | B3c persistent history no longer holds the secret after `replaceState` | **NO-GO** in both browsers | `logs/b3c-history-chromium.log`, `logs/b3c-history-firefox.log` | new |
| 10 | Non-extractable keys: export rejected; use not prevented | GO, with limit L2 | `logs/crypto-browsers.log` | re-ran |
| 11 | Fragment scrubbed; no key or token in page HTTP traffic; deliberate-leak control caught | GO (Chromium) | `logs/fragment.log` | re-ran |
| 12 | Upstream JS vectors + layout validation | GO, 61 pass | `logs/js-unit.log` | re-ran |
| 13 | Upstream Rust vectors | not re-run here | `../../reviews/2026-11-23-upstream-vectors.out` (reviewer's run, 51 pass) | taken from review |

## 1. Browsers, real media, label layout — GO

`node drive.mjs chromium|firefox <priv>` (env `CTX=label`, the default). Publisher alice and reader bob
each import the fragment secret as a non-extractable HKDF key, build the credential for a label's context,
and the reader walks `relay.announced()`. It takes the label from the first segment, builds that label's
credential, requires `opaque == path("call")`, and parses the epoch from the last segment.

- Chromium: `discovered alice/mI5WLvryMAlmeYGL3jVRWQ/<epoch>`, 15 distinct frames, audio RMS 0.65, peak 1.0, 49 decoded video frames.
- Firefox: same path shape, 15 distinct frames, audio RMS 0.68, 30 decoded video frames.
- Network leak scan of all page HTTP requests: 0 content-key representations (`contentKeyLeaks: 0`).

Video is VP8 by default (`codec=vp8`). The earlier agent needed VP8 to be forced for Firefox, and that is kept.

## 2. Native iroh-live — GO

`cargo test --features native-media --test complete_native -- --nocapture`. `LocalBroadcast`
(software H.264 320x180 + Opus tone) is published through `Node::publish_with` on an Iroh link to the
relay. A WebTransport reader discovers it by announcement, decrypts it and plays it with
`RemoteBroadcast`: 20 decoded frames, 20 distinct pixel checksums, 18,888 audio samples, peak 0.51.
A credential for another label does not match the opaque. No upstream fork. iroh-live lists four
tracks: `catalog.json`, `catalog`, `opus`, `video`.

## 3. Rust↔JS interop — GO, timestamp unauthenticated

`E2EE_PHASE=emit cargo test --test complete_interop`, then `bun interop.ts <dir>`, then `cargo test --test complete_interop`.
Rust→JS name, path and frame agree. JS→Rust decrypts. Rejected with `Authentication`: payload bit flip,
group change, semantic-name swap, wrong key, and (new) **another label's credential** reading the
frame. **A public frame timestamp changed from 124 ms to 999 ms still decrypts.** Through-relay
Rust↔browser in the label layout is claim 8.

## 4. Relay-key capture

`HARNESS=<pw dir> ./capture.sh plaintext|encrypted|tokenonly <priv>`. tshark 4.4.0 captures `lo0`. QUIC is
decrypted with the **harness relay's** keylog (`quic.keylog`, set only in `common.rs` when `E2EE_PRIVATE` is set).
STREAM frames are reassembled per connection and stream with no bridging of holes. Reference payloads
come from the publisher reading **its own** ciphertext from its local relay origin, which adds no wire traffic.
Checks run over every reassembled byte: the semantic markers `catalog.json`, `video`, `audio`, `alice/call`,
`call`, and the catalog display marker; VP8 keyframe headers (start code `9d 01 2a` with a plausible size);
VP8 decode of the captured video payloads (ffmpeg); the 440 Hz Goertzel ratio of the Opus-decoded captured
audio; and the content key in raw, hex and base64url.

| Run | On the wire | Captured payload matches (v/a) | Decoded VP8 frames | VP8 keyframe headers | 440 Hz ratio | Markers |
|---|---|---|---|---|---|---|
| plaintext control | pub + 2 subs, no encryption | 174 / 200 | 171 distinct | 12 | 0.995 | all present |
| **encrypted, passive** | pub alice + holders bob, carol only | 174 / 200 | **0** | **0** | **0.005** | **none** (all counts 0) |
| token-only (separate) | pub + holder bob + carol with token, no credential | 120 / 200 | 0 | 0 | 0.007 | `video` ×6 only |

Holders in the passive run decoded real media (15 distinct frames each, audio RMS 0.65). No content key in
any capture. Note: an Opus decoder turns ciphertext into "audio" (345k samples, RMS 244 in one run), so
decoder success is not a test; the tone ratio is.

**What the token-only client reveals (4c).** It sees every announcement (label, opaque, epoch). Its
semantic request `video` is refused (`remote error: 51`), and that request is the only place `video`
appears in plaintext-of-QUIC: 6 occurrences, none in the passive run with identical publisher code.
Given the physical names (which the relay learns from holders' subscriptions), it receives the
ciphertext frames (128 video, 200 audio, 1 catalog), and none of them decode. `remote error: 52` on audio
was observed and not investigated.

The first encrypted capture by the earlier agent (`capture-semantic-attack.log`) failed only because its
negative-test client was in the same capture. The cause is confirmed.

## 5. Label binding (review B1)

`cargo test --test b1_relabel -- --nocapture --test-threads=1`. The reviewer's probe was copied verbatim
from `reviews/2026-11-23-relabel-probe.rs`; that file is unchanged.

- **5a, D2 as written: NO-GO.** `relay_relabel_passes_d2_checks` is an expected-vulnerable test. It passes
  when the attack works. A session with no content credential re-served alice's ciphertext at
  `bob/<path(bob)>/<alice's epoch>`, and dave, applying D2's checks, decrypted `"ALICE-FRAME-35"` as bob's.
- **5b, label in context: GO.** `label_in_context_refuses_the_relabel`. The relay serves alice's ciphertext
  even under the physical name dave asks for, and dave gets `refused: Authentication`.
- **Which variant the earlier runs used:** variant (a) (`page.ts` built the context from the token root
  only, and `path(<label>)`; `chromium.log` shows `alice/YeprHZ7j…`, which is `path("alice")`). All
  browser, native, interop, rekey and capture runs above were redone on (b).

## 6. Rekey in the real layout

`node rekey-drive.mjs <priv>`. All runs used room tokens for alice, bob and carol, and the same
WebTransport session, and the readers found the new broadcast through `relay.announced()` with the epoch
parsed from the path. Nothing was handed over out of band **except the new credential itself**: it is a
fixture inside the page, because how an open page receives one (B3d) is not built. The earlier
`rekey-real.log` also used announcement discovery and room tokens, but on layout (a).

| | run 1 | run 2 | run 3 (machine overloaded) |
|---|---|---|---|
| A: new announcement seen by remaining reader | 18 ms | 17 ms | 16 ms |
| A: first frame from the new player | 156 ms | 201 ms | 148 ms |
| A: 15 frames + audio on new credential | 347 ms | 544 ms | 330 ms |
| A: removed member, old broadcast still up (1 s after switch) | +34 frames | +46 | +35 |
| A: removed member after retire: frames / last change | 21 / 722 ms | 14 / 513 ms | 23 / 5181 ms |
| A: removed member reading the new broadcast | discovery rule rejects; semantic read `remote error: 51` | same | same |
| B: retire old immediately: first new frame / longest stall | 191 / 190 ms, recovered | 191 / 191 ms, recovered | (watchdog) |

The unretired row is the positive control. The script throws unless the removed member keeps decoding while the old broadcast is up.

So: **a removed member with a valid token reads everything the publisher still sends under the old
credential, until the publisher retires it**, then only what was buffered (≤ 0.7 s in clean runs). It sees
the new announcement (label, new opaque, new epoch) but cannot use it. **A publisher that retires the old
broadcast at once does not break remaining readers that already hold the new credential**: about 190 ms
with no new frame, then normal playback. Run 3 ran under load average ~7 (the 7 s observation loop took 26 s).
Its tail and gap are reported but not relied on.

Findings from getting this to run:
- **F2, stale announcements share an opaque.** Every broadcast under one credential and label has the
  same opaque. With a fixed kid-2 secret across runs, a remaining reader switched to an *older* kid-2
  broadcast from a killed run whose session was still alive at the relay (`switched … 01a20c89-c6be…`,
  `next … 01a20c8b-4d3d…`). "Take the first matching active announcement" is wrong. A reader needs a rule
  that orders instances, either D2's greatest epoch or the reviewer's "most recently announced", and the
  relay can withhold the newer one (B4). Per-run secrets were then used to isolate the measurement.
- **F3, bridge manifest fragility.** A second encrypt bridge on the same local broadcast saw a track
  listed again and died on `Failure: reuse` (a JS generation refuses a name twice). Readers held a
  manifest snapshot taken before `audio`, so the switch carried no audio. Fixed in the harness: skip
  re-listed names, and republish the manifest every second.

## 7. Token expiry mid-call — behaviour pinned

`cargo test --test complete_expiry -- --nocapture --test-threads=1`.

- Bare: a WebTransport session with a 5 s token closes at 4970 ms with `Session(Expired)`. An Iroh link with a 10 s token drops to `Reconnecting` at 9991 ms.
- Subscriber token (3 s) in a live encrypted call: 70 frames, then `Session(Expired)` at 2931 ms. **A new session with a fresh token and the same content credential reads the same publisher epoch again** (48 frames in 2 s). No rekey.
- Publisher token (3 s): readers get `Stream(Unroutable)` at 2784 ms, and the publisher session ends `Expired`. **The publisher reconnecting the same local origin (same generation, so nonces continue) on a fresh token resumes readers** (48 frames, last `FRAME-113`).

What the client must do: obtain a new room token **before** `exp` and reconnect. The content credential, the
epoch and the generation all survive. A guest holding only an owner-minted link token cannot do this, so
today **a link guest's call ends at `exp`** (B3a), and only an owner-side refresh or delegated invite can fix that.

## 8. Wire surface (review B5)

**What each bridge puts on the wire, as pinned now:** at `<label>/<path("call")>/<epoch>`, one protected
track per semantic track (physical names derived by the profile), plus one protected track `bridge.tracks`.
Each group of `bridge.tracks` is one JSON frame
`{"<semantic>": {"timescale": units/s|null, "maxAgeMs": n|null, "priority": i8}}`, republished every second
by the browser bridge. Readers take track names only from this manifest, and nothing is hardcoded. The
earlier native bridge wrote `{"<semantic>": timescale}`, which the browser reader would misparse. It
now writes the browser format (`common.rs::manifest_entry`). The native reader ignores the values and
uses the TRACK_INFO of each physical track.

| Direction | Chromium | Firefox |
|---|---|---|
| browser reads native (`nat`, H.264 + Opus) | GO: 105 decoded frames, 15 distinct, audio peak 0.50 | GO: 63 decoded, 15 distinct, peak 0.50 |
| native reads browser (`alice`) | GO: 20 decoded, 20 distinct, 37,776 audio samples, peak 1.05 | not run (fixture's native reader takes the first `alice` only) |

`cargo test --features native-media --test complete_cross -- --ignored` (fixture), then `node cross-drive.mjs chromium <priv> 1` and `node cross-drive.mjs firefox <priv> 0`.

## 9. Persistent history (review B3c) — NO-GO in both browsers

`node history-drive.mjs chromium|firefox <priv>`. Persistent profile; a no-script control page with a
fragment, then the join with `#v=1&p=…&kid=1&k=<dummy key>&t=<token>`, then another page; the context is
closed and the store is read with `sqlite3`.

| | Chromium 159 (full build) | Firefox 159 |
|---|---|---|
| address bar fragment after join | empty | empty |
| control fragment in store (proves the store keeps fragments) | yes | yes |
| join URL **with** fragment in store | **yes** | **yes** |
| content key in store / room token in store | **yes / yes** | **yes / yes** |
| other profile files holding the key | `Sessions/Session_*`, `Sessions/Tabs_*`, `segmentation_platform/ukm_db` | none uncompressed (`sessionstore.jsonlz4` not scanned) |

`replaceState` fixes the address bar and the session-history entry only. The visit is written to global
history when the navigation commits, before any page script runs, so no page code can prevent it. The
spec's "from history" is false, and "session history" is the accurate wording. Options: say it in the page's
security note; deliver the secret some way other than a navigated URL (paste into the page, or a
`hashchange` on an already-open page, since same-document fragment navigations were not tested here); or
ask users to open links in private windows.

## 10–13

- **10 (GO, limit L2).** Both browsers reject `exportKey` on the HKDF root and on derived AES keys, and both derive 16 raw media-key bytes with `deriveBits` from the handle and decrypt (`sameOriginDecrypt: true`). `node crypto-drive.mjs`, with `complete-www/crypto.html` served on :8123.
- **11 (GO).** Fragment removed; 4 requests over 60 s; 0 key leaks; 0 token leaks in page or mint requests; deliberately leaked hex, base64url and raw bytes are all caught (3/3). `node fragment-drive.mjs <priv>`.
- **12 (GO).** `bun test src/e2ee.test.ts src/vectors.test.ts src/epoch.test.ts spike/validation.test.ts`: 61 pass, including both layouts and "the label layout derives different physical names per label for the same epoch; the room layout does not".
- **13.** Not re-run in this session.

## Limits found

- **L1. Frame timestamps are not authenticated.** 124 → 999 ms decrypts. A relay can shift presentation time.
- **L2. Non-extractable keys stop export, not use.** Any code holding the handle derives raw per-track key bytes for any public epoch and decrypts. Plaintext media is ordinary page data.
- **L3. Persistent history keeps the secret and the token** (claim 9), in both browsers, along with Chromium session files and UKM.
- **L4. One credential and label give one opaque for every broadcast.** Liveness alone does not pick the right instance (F2), so the reader rule needs ordering, and a relay can withhold the newer instance.
- **L5. A removed member reads the old broadcast until it is retired.** Removal is as fast as the slowest publisher's retirement, and retiring immediately costs remaining readers about 190 ms.
- **L6. Tokens end calls.** Expiry is enforced at `exp` on both transports. Continuity needs a client that can get a new token.
- **L7. Mixed-codec rooms.** The native player decodes H.264 only, so a browser publisher must send H.264 for native readers. Chromium and Firefox both report H.264 encode and decode support in WebCodecs.
- **L8. The relay sees labels and learns physical names.** The label is the clear first path segment. Physical names are visible in subscriptions, so a token-only client that the relay helps receives ciphertext.
- **L9. Ciphertext "decodes" as Opus.** Capture tests must check content (tone correlation), not decoder exit codes.

## Deviations from the contract that passing tests needed

- **D1. Label-in-context layout** (B1 option 1) in place of D2's room context with `path(<label>)`. Claims 1–4 and 6–8 pass only on it.
- **D2. A `bridge.tracks` manifest** as the wire surface (not in the contract; the reviewer preferred catalog-derived names). Both bridges implement one format.
- **D3. The browser publishes H.264** in the native-reads-browser direction.
- **D4. Harness bridge fixes:** skip re-listed names and republish the manifest every second (F3).
- **D5. Per-run random secrets** in the rekey driver, to keep stale announcements of killed runs from colliding (F2).
- **D6. Capture keylog** is enabled only on the in-process harness relay (B6). The shipped relay has no such switch, and none was added.

## Still INCONCLUSIVE, and what it would take

- **B3d credential hand-off to an open page.** The rekey test injects kid 2 into the page. It needs a `hashchange` or paste flow and a test that the new fragment also stays out of the network (and, per claim 9, it will land in global history if delivered by navigation).
- **Firefox publishing H.264 for a native reader, and Firefox rekey and capture.** Only Chromium was used for those runs. Each is one more driver invocation (`cross-drive.mjs firefox <priv> 1` on a fresh fixture).
- **Iroh-ingress publisher expiry with media.** Only the bare Iroh link close was timed.
- **Rekey under load.** Run 3 degraded badly at load average ~7. A rerun on an idle machine would show whether the 5 s tail is harness starvation or relay buffering.
- **Rust upstream vectors** in this session: rerun with `cargo test -p moq-e2ee` in the pinned checkout.

## Harness notes

Upstream worklet and libav Vite plugins are used unchanged. `@moq/libav` 0.1.0 is unpublished (npm 404). A
scratch Nix 2.24.11 built the pinned `.#moq-libav` (system Nix 2.17 is too old), and its output sits in
`<moq>/js/libav/dist`. Fixture TLS certificates last 7 days (WebTransport hash pinning). Private keylogs,
pcaps, certificates, tokens and media stay under `/tmp/mjolnir-e2ee-private*` and are never committed. The
only key material in this directory is the dummy fixture secrets 32×0x11 and 32×0x22, and logs are passed
through a token redactor.
