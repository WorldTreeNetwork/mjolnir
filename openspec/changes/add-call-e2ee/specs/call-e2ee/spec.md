## ADDED Requirements

### Requirement: Content credentials never pass through Mjolnir
A relayed call SHALL protect media, catalogs and semantic names against relay and host processes with client-generated `{profile, kid, secret}`. The origin serving browser code is trusted for this iteration (Duke, 2026-11-23); non-extractable keys do not prevent that origin from using keys or accessing plaintext. The secret SHALL be 32 cryptographically random bytes. For `moq-e2ee-01-wip`, each publisher label's credential context SHALL be `mjolnir-call/v1/<owner>/<room>/<label>`. Receivers SHALL derive it from the announced label and known room, rather than trust a transmitted context. Mjolnir SHALL NOT generate, receive, store, log or forward usable content key material. Derived opaque paths, physical names and ciphertext MAY reach the relay. Admission tokens are governed by `relay-room-auth`, independently of this credential; this capability SHALL NOT require a deployed relay change.

#### Scenario: No content credential at the mint
- GIVEN an owner starting a protected call
- WHEN the client obtains admission and publishes
- THEN no secret or usable derived key reaches the mint, relay or their logs
- AND the content secret is never derived from an admission token or server-held secret

#### Scenario: Token-only reader
- GIVEN a valid admitted reader without a content credential
- WHEN it lists the room
- THEN it can see every announcement's label, opaque and epoch
- AND a semantic-name probe returns NotFound
- AND given physical names it can fetch ciphertext but cannot recover the protected catalog or media content

### Requirement: Profile-specific broadcast identity and instance selection
For `moq-e2ee-01-wip`, a publisher SHALL announce `<label>/<opaque>/<epoch>` relative to the room root (Iroh absolute `t/<owner>/<room>/<label>/<opaque>/<epoch>`), with opaque equal to the label-context credential's `path("call")` and epoch the canonical UUIDv7 minted by produce(). A receiver SHALL validate the announced segments and derived opaque, consume with that label-context credential, and select the greatest canonical epoch among active matching announcements. It SHALL retain the greatest observed epoch per credential/label and SHALL NOT automatically downgrade when that instance disappears; it SHALL wait for a greater epoch or report unavailable. This ordering/layout belongs only to the profile named in the invite and SHALL be reconsidered at a successor-profile upgrade. Neither ordering nor authentication SHALL be represented as proof that a relay disclosed the newest instance. No encrypted room SHALL fall back to plaintext.

#### Scenario: Two holders
- GIVEN alice and bob sharing the room secret/kid and deriving label-specific credentials
- WHEN alice publishes at alice's derived opaque and epoch
- THEN bob discovers the announcement and decrypts using alice's context

#### Scenario: Relay swaps both label and opaque
- GIVEN alice's ciphertext under `alice/<opaque-alice>/<epoch-alice>`
- WHEN a relay serves it under `bob/<opaque-bob>/<epoch-alice>` and aliases it under the physical track names a bob-context reader requests
- THEN bob-context authentication fails even though the opaque and canonical epoch checks pass

#### Scenario: Stale instance remains active
- GIVEN two matching active epochs under one label and credential
- WHEN the older announcement arrives first
- THEN the reader chooses the greatest canonical epoch
- AND when that selected instance disappears the reader does not automatically revert to the older one

### Requirement: One confidential bridge wire surface
Both bridges SHALL carry one protected track per semantic local track, including catalogs, plus a protected `bridge.tracks` manifest. Each manifest group SHALL contain one JSON frame mapping semantic names to `{timescale: units/s|null, maxAgeMs: number|null, priority: i8}`. Publishers SHALL send a complete current snapshot on track-set changes and refresh it every second while live. Receivers SHALL derive physical names from manifest entries and the consuming generation; metadata SHALL agree with TRACK_INFO. Publishers SHALL suppress duplicate track listings within a generation rather than recreate a protected track with the same name. Semantic names SHALL be at most 15 UTF-8 bytes; display names SHALL be encrypted. A browser publisher SHALL use H.264 when a native reader is present. Plaintext local origins SHALL never be attached to a relay session, including stats/echo paths.

#### Scenario: Late reader and re-listed audio
- GIVEN either bridge has added audio after its initial manifest
- WHEN a reader subscribes late and the source lists an existing track again
- THEN periodic manifest snapshots include audio and the reader derives its physical name
- AND the publisher retains the existing protected track without a duplicate-name failure

### Requirement: Removal retires old publication immediately
After receiving a greater kid and fresh secret, a remaining publisher SHALL mint and announce a new generation, then immediately stop old-key encryption, finish old tracks and close the old broadcast without waiting for reader acknowledgements. Withdraw alone SHALL NOT count as retirement. A remaining reader MAY retain its old credential read-only until old broadcasts end. Same-session switching is required only for clients supplied the replacement credential in-app; for link guests without that mechanism, replacement invitations and rejoin are the baseline. Room-wide removal SHALL NOT be reported complete while any remaining publisher still publishes under the old credential. Buffered old content and recorded content cannot be recalled.

#### Scenario: Removed member and slow hand-out
- GIVEN carol retains the old credential and a valid admission token
- WHEN alice adopts kid 2 and immediately retires kid 1
- THEN bob, already supplied kid 2, follows the new announcement without a session restart, allowing a temporary playback stall
- AND carol receives no newly encrypted old-key frames after alice's retirement, though buffers may drain
- AND another publisher not yet supplied kid 2 continues feeding carol, so room-wide removal is not yet complete

### Requirement: Content delivery and browser persistence limits
A link-delivered content credential SHALL be confined to its URL fragment, imported into a non-extractable HKDF handle after length validation, and removed from the address bar and current session-history entry on page load. The page SHALL NOT claim this erases persistent/global history or browser session files: both tested browsers persist the navigated invite before page script runs. Release SHALL wait for the explicit delivery decision: accept this limit and disclose it in the page security note, or deliver the secret outside a navigated URL. The page SHALL NOT send the secret or usable keys in HTTP requests or error reports, or persist raw secret material in application storage. If an admission token is delivered in a link, it SHALL go only to intended relay admission, not other requests/reports. Derived opaque protocol data MAY go to the relay. The page SHALL serve Referrer-Policy no-referrer and no third-party scripts.

#### Scenario: Join URL scrubbing is narrower than history erasure
- GIVEN a browser navigates to a dummy credential invite
- WHEN page initialization replaces the current URL and the persistent profile is later inspected
- THEN the address bar and current session-history entry omit the fragment
- AND retained invite/key/token in persistent history is reported as a delivery limit, not a failed erasure promised by this capability

#### Scenario: Network leak positive control
- GIVEN a one-minute fixture join and deliberately leaking fixtures
- WHEN page/mint requests and reports are scanned for raw, base64url and hex secret forms
- THEN the join has no secret leak and the deliberate leaks are detected
- AND token use is limited to relay admission

### Requirement: Producing generation belongs to its process instance
Each new publishing process instance SHALL mint its producing generation with produce(). A live reconnect MAY retain the generation only with its original nonce/claim state intact. A client SHALL NOT restore or reset producing counters under an existing generation. Guest snapshot support is outside this capability.

#### Scenario: New process versus live reconnect
- GIVEN a publisher disconnects from transport
- WHEN the same live process reconnects with intact claims
- THEN it may retain its generation without rekey
- AND a replacement process mints a new generation rather than resuming serialized producing state

### Requirement: Experimental profile and resource limits are explicit
Rust and browser adapters SHALL pin moq `4a6f52248` for the development profile `moq-e2ee-01-wip`; default-on release profile awaits Duke's choice. Links SHALL name the profile and clients SHALL refuse unsupported profiles explicitly. A derivation/profile upgrade SHALL be coordinated across clients and revalidate layout, instance selection and bridge wire surface without a relay change. Release checks SHALL include shared vectors in both languages, browser/native relay interop and tamper cases. At the WIP pin, producers reaching 2^36 bytes or 2^24 operations per key SHALL stop and mint a new generation. Consuming exhaustion MAY rebind the same epoch with bounded retry; repeated failure SHALL be visible, never trigger plaintext fallback.

#### Scenario: Unsupported profile or exhausted key
- GIVEN a client has only the pinned development profile
- WHEN an invite names an unsupported profile or a producing key exhausts its budget
- THEN unsupported profiles join no plaintext broadcast
- AND exhaustion advances producing generation instead of resetting the old key's counters

### Requirement: Relay-key acceptance checks content on a test harness
Acceptance SHALL use an in-process harness relay built from the same mjolnir-relay crate with harness-only QUIC keylog. The shipped binary SHALL NOT gain a runtime keylog switch and production SHALL NOT be captured for this test. A plaintext positive control SHALL establish nonempty decrypted/reassembled MoQ data and recover injected media/catalog/name content. A separate passive encrypted two-holder call SHALL reveal no publisher semantic markers or recognizable injected media while both holders play it. A separate token-only run SHALL distinguish its own semantic-name probes from publisher leaks. Captures SHALL test content, including video frames/headers and audio tone correlation, not decoder exit status: Opus can decode ciphertext into noise. Session keys, tokens and pcaps SHALL remain private test artifacts.

#### Scenario: Passive capture versus active probe
- GIVEN plaintext, passive encrypted and token-only captures decrypted with harness session keys
- WHEN reassembled bytes and injected audio/video content are checked
- THEN plaintext recovers recognizable content and passive encrypted traffic does not
- AND token-only semantic probes may appear in transport plaintext without exposing publisher semantic names
- AND successful Opus decoder exit alone counts as neither recovered content nor encryption failure
