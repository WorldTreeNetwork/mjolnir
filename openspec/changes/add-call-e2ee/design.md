# add-call-e2ee — design

Architecture rigor: cryptography and protocol. Every claim below cites a spike transcript in `spikes/` or says it was not run. Spike sources: `spikes/rust/tests/` (one crate, real `moq-relay` with the Mjolnir WebTransport decider and Iroh session handler, tokens with exactly the claims `Mjolnir.Relay.Mint.sign/7` writes) and `spikes/js/`. Re-run any Rust spike with:

```bash
cd openspec/changes/add-call-e2ee/spikes/rust
CARGO_TARGET_DIR=../../../../../native/mjolnir_relay/target cargo test --test <e2ee_path|e2ee_iroh_live|e2ee_rekey> -- --nocapture
```

## Spike verdicts

| Spike | Verdict | Evidence |
|---|---|---|
| e2ee-path | **Proven** | `spikes/e2ee-path.out`. `alice/<opaque>` admitted under the unchanged room token; bob decrypts `"PLAINTEXT-MARKER-video-0"` and the catalog; carol (token, no credential) gets `NotFound` for `"video"` and for a wrong secret, and 40 bytes with no marker on the physical name (24 plaintext + 16 tag). Epoch in the last path segment, label-bound opaque, default wire: bob decrypts. |
| e2ee-js | **Proven for frames; components not run** | `spikes/e2ee-js.out`: Chromium 158 and Firefox 159 decrypt catalog and three frames over WebTransport/moq-lite-06; no-credential reader sees ciphertext, wrong-secret subscription fails. `spikes/e2ee-js-components.out`: bundle fails on upstream worklet/CSS imports before browser launch. Hang watch/publish integration is not run. |
| e2ee-iroh-live | **Proven, with a bridge** | `spikes/e2ee-iroh-live.out`. An `iroh_live::Node` publishes `t/<owner>/r1/alice/<opaque>` through `publish_with`; a WebTransport subscriber decrypts `"PLAINTEXT-MARKER-iroh-42..44"`. iroh-live's real `LocalBroadcast` encoder behind the bridge: **not run**. An iroh-live subscriber/player reading a protected broadcast: **not run**. |
| e2ee-rekey | **Proven** | `spikes/e2ee-rekey.out`. kid 2 decrypts at bob 47–48 ms after the new credential, same sessions; carol sees the kid 2 path and gets `NotFound`. First run refuted "withdraw is enough": carol received 51 more kid 1 frames. |

Two findings changed the design:

1. **The epoch does not survive the default wire.** At this pin, `moq_net::Versions::all()` excludes `moq-lite-07-wip`, and the production relay (`native/mjolnir_relay/src/main.rs` sets no `listen.version`) negotiates an older lite. The relay then mints its own route instance: bob saw `Instance("7b76…", "minted")` and `Epoch::of` returned `None`. With lite-07 opted in on relay and clients, the instance carried the epoch. iroh-live's `Node::publish` routes with `RouteOptions::hidden()` and no instance, so its epoch is minted regardless of wire (`Epoch::of` = `None` in e2ee-iroh-live). D2 puts the epoch in the path.
2. **Removal must end the old broadcast.** `Route::withdraw` hides a route from new subscribers. A subscriber already reading keeps receiving whatever the publisher still writes. D5.

## Decisions

**D1. Two credentials, never mixed.**
The room token (moq-auth JWT, `relay-room-auth`) decides who may open a session and under which label they may publish. The content credential decides who may read. Mjolnir mints, logs and can revoke-by-expiry the first. It never generates, receives, stores, logs or forwards the second. Derived opaque paths, physical track names and ciphertext necessarily reach the relay; these are not the secret or usable key material. The relay's grant is unchanged: root `t/<owner>/<room>`, publish `[<label>/**]`, subscribe `[**]`. Alternative: derive the content key from something Mjolnir holds (the token, a server secret). Rejected: then the operator can read the calls, which is the property this change exists to remove.

**D2. Path layout: `t/<owner>/<room>/<label>/<opaque>/<epoch>`.**

- `<label>` is the room-token participant label. The relay's `<label>/**` grant binds it. The shipped client SHOULD pick a random label (`[A-Za-z0-9_-]{16}`) per join; the display name rides only in the encrypted catalog.
- `<opaque>` is `credential.path(<label>)`: 22 base64url characters, HKDF of `(context, kid, label)`. Binding it to the label means a relay that re-mounts alice's broadcast under `bob/` is caught: the subscriber recomputes `path("bob")` and it does not match (proven in the epoch-in-path test). Different credentials give different opaques, so old and new generations of one label coexist during a rekey.
- `<epoch>` is the publisher instance's UUIDv7 text (`Epoch::mint`, never chosen). Subscribers parse it from the announced path (`Epoch: FromStr` refuses non-canonical text) and bind it with `credential.consume(epoch)`.

This departs from the draft-01 layout (`<opaque>` with the epoch as the route Instance). The cryptography is the draft's: every key, nonce and physical name is derived exactly as `moq-e2ee` derives it; only where the subscriber learns the epoch differs (draft-00 had it as the last path segment). Options weighed:

| Option | Default wire | iroh-live publisher | Evidence | Cost |
|---|---|---|---|---|
| A. Route Instance (draft-01) | No: relay mints | No: Node mints | e2ee-path both ways; e2ee-iroh-live | Relay and every client opt into `moq-lite-07-wip`, a WIP wire; iroh-live needs an instance option (fork or upstream) |
| **B. Last path segment (chosen)** | Yes | Yes (caller names the path) | epoch-in-path test | Not draft-01 conformant in layout; epoch visible (it is in A too) |
| C. Application channel | Yes | Yes | not run | Needs a signalling channel the platform does not have for guests |

A subscriber picks the greatest epoch announced under a label's opaque (UUIDv7 sorts by creation time) and follows announce events to the next one, which is the resubscribe-on-announce `mjolnir-rurh.5` already owes (relay-room-auth C6). **Needs Duke / advise:** B is a deliberate deviation from the upstream profile's layout.

**D3. The credential reaches a browser guest in the URL fragment, and nowhere else.**
Link: `https://<call page>/#v=1&p=moq-e2ee-01-wip&kid=<u53>&k=<43 base64url chars>&t=<room token>`. `context` is not in the link; both ends derive it as `mjolnir-call/v1/<owner>/<room>` from the token's root. A user agent dereferences a fragment locally and does not send it in the request target (RFC 3986 §3.5), and `Referer` must not include it (RFC 9110 §10.1.3). A task below checks this with a captured network log rather than trusting the RFCs. The page owes:

1. Read `location.hash` once at load, then `history.replaceState(null, "", location.pathname + location.search)` so the secret is not left in the address bar or session history.
2. Never place `k` or usable key material in a request URL, header, body, `postMessage` to another origin, storage readable by another origin, or an error report. The room token `t` goes only to the intended relay as its existing `jwt` query parameter (WebTransport) or admission credential (Iroh); it must never reach other page requests or reports. Derived opaque paths, physical names and ciphertext go to the relay by design. Hold the secret in a `CryptoKey`-like closure, not in `localStorage`.
3. Serve with `Referrer-Policy: no-referrer`, a CSP whose `connect-src` is the page's own origin and the relay host, and no third-party script.
4. The mint route is never called by a guest (relay-room-auth: the owner mints and hands the token over). The owner's mint request body carries only `ttl`; there is no field the credential could travel in, and the mint log line has room, label, `jti`, `exp` only.

What this does not cover: whoever serves the page's JavaScript can serve code that reads the fragment. If Mjolnir serves the page, Mjolnir is trusted for code integrity though not for transport. That is the standing limit of web E2EE. It is `mjolnir-rurh.5`'s decision where the page is served from (a pinned, content-addressed site; SRI; a native client). **Needs Duke:** whether shipping the page from the same operator is acceptable for "on by default".

**D4. Native iroh-live publishers take part without a fork.**
`iroh_live::Node::publish_with(path, audience, fill)` gives the caller the `moq_net::broadcast::Producer` before it is announced. The caller wraps it in `moq_e2ee::broadcast::Producer` and creates the protected tracks in `fill` (proven). iroh-live's media pipeline (`moq_ext_publisher::LocalBroadcast`) writes plaintext into a broadcast it owns, so a native publisher runs it on a local, never-announced broadcast and bridges each group into the protected track: same group start, same frame timestamps, payload sealed (`spikes/rust/tests/e2ee_iroh_live.rs::bridge`, proven with a plain local broadcast standing in for `LocalBroadcast`; the real encoder: not run). Iroh spells the absolute path; WebTransport the token-relative one (relay-room-auth). The subscriber side is the mirror (decrypt into a local plaintext broadcast for `moq-ext-player`): not run.

If the bridge cannot carry a real encoder (for example, if `LocalBroadcast` needs demand signals the bridge does not forward), the fallback is an upstream hook in `moq-ext-publisher` that accepts a caller-supplied track factory, offered to n0 as a PR. Until one of the two works, a native iroh-live participant without the bridge sees only ciphertext in an encrypted room and is not supported there; the room does not fall back to plaintext for it.

**D5. Removing a member is a new credential; the old broadcast is ended.**
The draft has no in-epoch rekey and no revocation ("The profile does not distribute keys … or rotate a key inside an epoch"). Removal:

1. The owner's client mints `kid + 1` with a fresh secret and gives it to the remaining members over the same channel the first credential used.
2. Each remaining publisher mints a new generation under it and announces `<label>/<opaque'>/<epoch'>` on its open session, beside the old broadcast.
3. Each remaining subscriber follows the new path on its open session. In the spike bob decrypted kid 2 47–48 ms after the publisher announced it.
4. Each publisher then **finishes its old tracks and closes the old broadcast**. Withdraw alone left carol receiving 51 more frames.

Nobody reconnects; everyone remaining resubscribes. A publisher that misses step 4 keeps feeding the removed member.

What the removed member still has: a room token valid until its `exp`, up to 3600 s (relay-room-auth Limits: no early revocation). Until then they can connect, list the room's announcements, and fetch ciphertext under the new credential. They learn labels, opaques, epochs, sizes and timing. They cannot derive the new physical names (`NotFound`, proven) or decrypt. They can also publish noise under their own label, which remaining members ignore because it is not under the current credential's opaque. Content access ends at step 4; metadata access ends at token `exp`. Nothing un-shares what they already recorded.

A member whose token expires and who is not re-minted is out of the relay as well. Short tokens shorten the metadata window, but are capped below by the handoff gap the client must bridge (relay-room-auth C6).

**D6. Catalog and track names.**
A physical track name is `nonce ‖ AES-128-GCM(name_key, nonce, pad16(semantic ‖ 0x80))`, base64url. The relay learns only the padded length. Every semantic name of 15 bytes or less pads to 16 and gives a 59-character physical name (`"video"` and `"catalog.json"` both did in e2ee-path). The shipped client keeps every semantic track name ≤ 15 bytes so all physical names are one length class. The catalog is an ordinary protected track; inside it semantic names stay (that is how subscribers derive physical names). Display names live only in the catalog. What the relay can still count: tracks per broadcast, stream versus datagram, group cadence, frame and datagram sizes, timestamps. Subscribing a semantic name returns `NotFound` (proven); a forged physical name opens nothing and costs the publisher no state (draft §derive).

**D7. Pinning `moq-e2ee-01-wip`, and what moves when the draft moves.**
We pin moq `4a6f52248` for `moq-e2ee` (git dependency; upstream `publish = false`) and consume `js/e2ee` from source at the same revision (upstream `"private": true`). The profile string is the HKDF salt and the prefix of every label. A new profile (`-01`, `-02`) changes every opaque path, physical name and key. Clients on different profiles do not find each other's broadcasts at all: a silent no-show, never plaintext, never a wrong-key decrypt. Consequences:

- The link names the profile (`p=`). A client refuses a profile it does not implement and says so. One room runs one profile.
- A bump is a coordinated client upgrade. The browser client updates on reload. Native clients lag, and an invite with the new profile is unreadable to them until they update.
- The relay is untouched by a bump. It sees paths and bytes.
- CI runs the draft's vectors (`drafts/moq-e2ee-01-wip.json`) through both the Rust crate and `@moq/e2ee` at our pin, and a Rust↔JS interop test, so a pin bump that silently changes either side fails before it ships.
- The epoch-in-path layout (D2) is ours. If upstream changes how the epoch travels, D2 does not move with it.

**D8. Cloned process images re-mint.**
Two copies of one producing generation reuse AES-GCM nonces under one key, which is catastrophic and undetectable on the wire (draft §epoch). Mjolnir snapshots and thaws VMs (`vm-freeze`). Any publisher that runs inside a Mjolnir guest SHALL call `produce()` again when the VM generation id changes, and SHALL NOT encrypt another frame under the old generation. Browser tabs and native processes are not cloned by Mjolnir. This change ships no guest publisher; the requirement binds the change that does.

**D9. Acceptance: a capture at the relay process, with the relay's keys.**
The bead's acceptance is run as `tasks.md` §Acceptance: the relay runs with `quic.keylog` (moq-tokio's `--quic-keylog` / `quic.keylog` setting) so the tester holds the relay's QUIC session secrets; `tshark` records UDP 443 on the relay host for a two-client call; `tshark -o tls.keylog_file:<file>` decrypts the QUIC streams; the decrypted MoQ payload is searched for known plaintext the clients injected (a marker in every media frame, the catalog's display name, every semantic track name and the semantic broadcast name `call`). A third client with a token and no credential records what it receives. A relay-side tap (an all-room subscriber session with no credential) is the cross-check for what the relay process itself can assemble.

## What the relay and host can see

| Visible | Example | Hidden |
|---|---|---|
| Owner id, room, participant label | `t/cGfH…/r1/alice` | Display names, what a label means |
| Opaque segment (per label, per credential) | `WizDAU0CTwZI5yCky5IYrg` | The semantic broadcast name |
| Epoch (UUIDv7: publisher start time to the ms) | `01a20af5-67f8-…` | — |
| Physical track names, count, kind, length class | 59 chars each | Semantic track names, the catalog |
| Group/frame structure, sizes, timestamps, cadence | 40-byte frame = 24 + 16 | Payload bytes |
| Who connects when, with which token | mint log, relay log | — |

## Open questions

- Whether D2's departure from the draft-01 layout is acceptable, or whether we should instead push lite-07 onto the relay and iroh-live (Duke / advise).
- Whether the shipped page may be served by the operator (D3).
- The real `LocalBroadcast` encoder through the bridge, and the iroh-live subscriber mirror (D4): not run.
- The removal window: a removed member keeps metadata visibility for up to 3600 s. Shorter default tokens are blocked on the C6 handoff.
- Opus/VBR size leakage is out of scope; a constant-bitrate audio setting in the client would reduce it and is `mjolnir-rurh.5`'s call.


## Unverified hypotheses

- **e2ee-js-components** — unmodified Hang publish/watch can bridge a real encoder and player; confidence low, verification not run (bundle blocked before launch); synthesis: `spikes/e2ee-js-components.out`. Resolve with upstream Vite worklet/libav plugins and a moving-image plus audio observation in both browsers before supporting the shipped client.
- **e2ee-native-media** — `LocalBroadcast` demand/encoder and player can traverse the in-process bridge; confidence medium, verification not run; synthesis: `spikes/e2ee-iroh-live.out` proves only synthetic local frames through Node. Run the real pipeline; fallback is the upstream factory hook in D4.
- **e2ee-fragment** — the shipped page sends no secret in requests or logs; confidence medium, verification not run (no shipped page yet). Synthesis path: future `evidence/fragment-network.out`, with captured requests and deliberate leak positive control.
- **e2ee-capture** — relay-session-key capture exposes MoQ control and ciphertext while two clients play real media; confidence medium, verification not run. Synthesis path: future `evidence/relay-capture.out`; method below and tasks A1–A3.

## Acceptance capture method and limits

D9 is a proposed method, not a completed capture. First prove tshark can decrypt and reassemble this pinned QUIC/MoQ traffic. Save the keylog, pcap and extracted stream/datagram bytes in a private test artifact location (session keys are sensitive), with tool versions and commands in the transcript. The capture must include the relay's actual UDP listener and both clients. An opaque pcap or zero extracted bytes fails the test.

Run a plaintext positive control with the same harness and injected media/catalog markers: the extracted bytes must contain those markers and semantic names and the unprotected media must decode. Then run the protected call, verify decrypted transport control contains the announced opaque paths and physical track names, and search reassembled application bytes for those exact markers and names. Attempt media decoding from the relay-side bytes; it must fail while both credential holders render moving video and play audio. A token-only tap records ciphertext and fails to decode it. Search results alone do not prove absence of decodable media. If tshark cannot reassemble this wire revision, instrument a relay-process application tap after QUIC decryption, retain the pcap/keylog as a cross-check, and return the changed acceptance method for advise rather than claim the capture passed.

The browser fixtures use public/no-auth local relay and fixed dummy keys in query parameters for convenience. They prove crypto/browser API compatibility only. They deliberately do not implement the invite fragment, room admission, secret handling, epoch-in-path layout, or production security headers. Those properties need their own tests. Rust's room-token and path spike covers admission separately; composing all these layers remains acceptance work.
