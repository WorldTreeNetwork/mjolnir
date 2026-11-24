> Draft placeholders (non-normative): default-on profile, navigated-link versus paste delivery, and per-call versus standing-room secret policy remain Duke ASKs in tasks.md. The development profile and navigated-link behaviour below are proposed targets; replace the affected behaviour with his choice before folding. These pending decisions are not runtime requirements.

## ADDED Requirements

### Requirement: Content credentials never pass through Mjolnir
A relayed call SHALL protect media, catalogs and semantic names against relay and host processes with client-generated `{profile, kid, secret}`. The origin serving browser code is trusted for this iteration (Duke, 2026-11-23); non-extractable keys do not prevent that origin from using keys or accessing plaintext. The owner's explicit CreateCredential action SHALL generate 32 cryptographically random secret bytes; subsequent invitations in that active credential lifecycle SHALL use the same secret/kid until rekey or end. For `moq-e2ee-01-wip`, each publisher label's credential context SHALL be `mjolnir-call/v1/<owner>/<room>/<label>`. Receivers SHALL derive it from the announced label and known room, rather than trust a transmitted context. Mjolnir SHALL NOT generate, receive, store, log or forward usable content key material. Derived opaque paths, physical names and ciphertext MAY reach the relay. Admission tokens are governed by `relay-room-auth`, independently of this credential; this capability SHALL NOT require a deployed relay change.

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
For `moq-e2ee-01-wip`, a publisher SHALL announce `<label>/<opaque>/<epoch>` relative to the room root (Iroh absolute `t/<owner>/<room>/<label>/<opaque>/<epoch>`), with opaque equal to the label-context credential's `path("call")` and epoch the canonical UUIDv7 minted by produce(). A receiver SHALL validate segments and opaque and try candidate epochs greatest first. An instance SHALL be accepted only after a frame from it authenticates under the label-context credential. An announcement alone SHALL NOT advance the mark. The receiver SHALL retain the greatest accepted epoch per credential/kid/label only in page memory for that page's lifetime. It SHALL skip authentication failures and candidates with no authentic frame within 1500 ms, falling through to a candidate at or above the mark while keeping an accepted stream playing. It SHALL attempt at most 12 new candidates per label per rolling 60 seconds, one at a time, without retrying a failed epoch within that window. Exhausting this budget SHALL produce a retryable unavailable state without clearing the mark/accepted stream. It SHALL NOT render a below-mark instance automatically; when only older instances remain it SHALL show “newer stream expected, older one present”. Reload SHALL discard the mark. A publisher SHALL watch its own label using the same authentication rule; when another greater instance authenticates it SHALL stop its own publication and tell the user “you joined somewhere else”. Resuming on that device by explicit user action SHALL mint a new generation. No encrypted room SHALL fall back to plaintext.

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
- THEN the reader tries candidates greatest first and accepts only an authenticating instance
- AND when that selected instance disappears the reader does not automatically revert below its authenticated mark

#### Scenario: Forged greater announcement
- GIVEN a real authenticating instance and a relay announcing a greater canonical epoch with the same public opaque
- WHEN the forged candidate fails authentication or times out within 1500 ms
- THEN it does not advance the mark and the reader tries the real candidate within the per-label attempt budget
- AND a currently accepted stream keeps playing

#### Scenario: Second device under one label
- GIVEN a laptop publishes E1 and a phone using the same invite publishes greater E2
- WHEN an E2 frame authenticates at the laptop and other readers
- THEN readers mark E2 and the laptop stops E1 publication with “you joined somewhere else”
- AND an explicit resume action on the laptop mints a new generation, rather than resuming E1 counters

#### Scenario: Reload is a fresh reader
- GIVEN the page accepted E2 and scrubbed its invite URL
- WHEN the page reloads
- THEN no instance mark or credential is restored from application storage and the page asks for the invite again
- AND after re-entry it is a fresh reader with no persisted E2 mark


### Requirement: One confidential bridge wire surface
Both bridges SHALL carry one protected track per semantic local track, including catalogs, plus a protected `bridge.tracks` manifest. Each manifest group SHALL contain one JSON frame mapping semantic names to `{timescale: units/s|null, maxAgeMs: number|null, priority: i8}`. Publishers SHALL send a complete current snapshot on track-set changes and refresh it every second while live. Receivers SHALL derive physical names from manifest entries and the consuming generation; authenticated manifest metadata SHALL be authoritative for local tracks. A mismatch with relay-supplied TRACK_INFO SHALL reject the affected track with a visible metadata error rather than substitute relay values. Publishers SHALL suppress duplicate track listings within a generation rather than recreate a protected track with the same name. Semantic names SHALL be at most 15 UTF-8 bytes; display names SHALL be encrypted. Plaintext local origins SHALL never be attached to a relay session, including stats/echo paths.

For invite `v=1` and context `mjolnir-call/v1/...`, the manifest SHALL use exactly this map shape; unsupported invite/context versions SHALL be refused. Before creating subscriptions the reader SHALL reject an entire snapshot exceeding 16 KiB of UTF-8 JSON or 32 entries, duplicate keys, empty/non-string names, names longer than 15 UTF-8 bytes, non-object entries, extra metadata fields, or invalid values. Timescale SHALL be null or a positive safe integer; maxAgeMs SHALL be null or a finite nonnegative safe integer; priority SHALL be an integer in [-128,127]. A snapshot SHALL be applied atomically only after authentication and validation, with one frame per group and a group start strictly greater than the last applied manifest group for this kid/label/epoch. Older or duplicate groups and their late frames SHALL NOT replace newer metadata. The reader SHALL NOT partially apply an invalid snapshot.

#### Scenario: Bounded and ordered manifest
- GIVEN a valid authenticated v1 snapshot from group G has been applied
- WHEN an oversized snapshot, invalid metadata, duplicate keys, or an authenticated snapshot at or below G arrives
- THEN subscriptions and metadata do not change
- AND a valid greater snapshot uses its authenticated metadata, refusing conflicting relay TRACK_INFO


#### Scenario: Late reader and re-listed audio
- GIVEN either bridge has added audio after its initial manifest
- WHEN a reader subscribes late and the source lists an existing track again
- THEN periodic manifest snapshots include audio and the reader derives its physical name
- AND the publisher retains the existing protected track without a duplicate-name failure

### Requirement: Removal retires old publication immediately
The owner SHALL deliver a replacement credential with a greater kid, fresh secret and a canonical removedLabels list alongside it. A reader adopting it SHALL immediately stop rendering/unsubscribe removed labels, including buffered old media. For every other label it MAY retain an old credential read-only only until that label has an accepted/authenticated instance under the new kid; it SHALL then stop that label's old subscriptions and discard its old consuming handles. It SHALL discard the old credential handle when no retained labels need it, or on leave/reload. Old credentials SHALL NOT be used to produce after adoption.

A remaining publisher SHALL mint and announce a new generation, then immediately stop old-generation sealing, finish old tracks and close the old broadcast without waiting for reader acknowledgements. Withdraw alone SHALL NOT count as retirement. Same-session switching applies only to clients supplied the replacement credential in-app; replacement invitation and rejoin remain the link-guest baseline. The page SHALL warn a rejoining guest to close the old tab, unless a tested same-origin stop mechanism retires it. Owner-side completion SHALL mean every label in the owner's locally maintained set of replacement recipients has an accepted/authenticated instance under the new kid; it SHALL show missing labels as pending, not infer completion from absent old announcements. If reload loses the owner's removal-cycle recipient set, completion SHALL be unknown until that set is re-established by the owner, never inferred from relay announcements. This observation does not attest termination of other tabs. Buffered and recorded content cannot be recalled.

#### Scenario: Removed member and slow hand-out
- GIVEN carol retains the old key/token and continues her own old broadcast
- WHEN bob adopts a replacement listing carol as removed
- THEN bob stops rendering carol immediately even if her old broadcast never ends
- AND bob may read another non-removed label with the old key only until that label's new-kid instance authenticates

#### Scenario: Retirement is asserted at the publisher
- GIVEN alice adopts kid 2 and announces its new generation
- WHEN alice's retire call returns
- THEN instrumentation at alice observes no subsequent old-generation seal calls
- AND the reader may still drain already encrypted buffered frames, which does not establish new sealing
- AND a reader without kid 2 loses alice's media for as long as delivery takes, even minutes for hand-delivered links

#### Scenario: Owner observes completion but an old tab remains
- GIVEN the owner issued replacements to alice and bob and has not accepted bob under the new kid
- WHEN old announcements disappear
- THEN completion remains pending bob
- AND when both new-kid instances authenticate the owner's observed completion condition is met
- AND an old tab still publishing is a stated limit requiring closure or the page's stop mechanism, not proof obtained from that completion condition


### Requirement: Content delivery and browser persistence limits
A link-delivered content credential SHALL be confined to its URL fragment, imported into a non-extractable HKDF handle after length validation, and removed from the address bar and current session-history entry on page load. The page SHALL NOT claim this erases persistent/global history or browser session files: both tested browsers persist the navigated invite before page script runs. The page SHALL NOT send the secret or usable keys in HTTP requests or error reports, or persist raw secret material in application storage. Guest handles SHALL remain in page memory only. The owner's secret/invite copy for later invitations SHALL live only in a private page-memory closure, not persistent storage. Leave, call-end or replacement SHALL discard obsolete application references, apart from read-only consuming handles allowed above; reload SHALL lose the current credential/owner copy, join nothing and ask for the invite again. A new call without a retained external invite SHALL create a new credential, not recover from application storage. If an admission token is delivered in a link, it SHALL go only to intended relay admission, not other requests/reports. Derived opaque protocol data MAY go to the relay. The page SHALL serve Referrer-Policy no-referrer and no third-party scripts.

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

### Requirement: Live readers advance group order only on authentication
For each protected track/kid/label/epoch, the reader SHALL keep a page-memory group-start mark advanced only by an authentic frame. For a manifest it SHALL also require snapshot validation. It SHALL NOT reopen newly offered groups at or below the mark; frames within the currently accepted group MAY continue in order until a greater group authenticates, after which its older tail SHALL be discarded. The reorder allowance SHALL be zero. A non-authenticating high group SHALL NOT advance the mark. This does not reject never-seen delayed content or establish freshness after a reload.

#### Scenario: Replay to a reader already in the call
- GIVEN a reader has authenticated group G2 after G1 in one protected track
- WHEN a relay re-serves G1 with a current public timestamp or presents an unauthenticating higher group
- THEN G1 is not reopened/rendered and the failed higher group does not advance the mark
- AND an older authenticated manifest cannot roll back the current track set


### Requirement: Producing generation belongs to its process instance
Each new publishing process instance SHALL mint its producing generation with produce(). A live reconnect MAY retain the generation only with its original nonce/claim state intact. A client SHALL NOT restore or reset producing counters under an existing generation. Guest snapshot support is outside this capability.

#### Scenario: New process versus live reconnect
- GIVEN a publisher disconnects from transport
- WHEN the same live process reconnects with intact claims
- THEN it may retain its generation without rekey
- AND a replacement process mints a new generation rather than resuming serialized producing state

### Requirement: Experimental profile and resource limits are explicit
Rust and browser adapters SHALL pin moq `4a6f52248` for the development profile `moq-e2ee-01-wip`. Links SHALL name the profile and clients SHALL refuse unsupported profiles explicitly. A derivation/profile upgrade SHALL be coordinated across clients and revalidate layout, instance selection and bridge wire surface without a relay change. Release checks SHALL include shared vectors in both languages, browser/native relay interop and tamper cases. At the WIP pin, producers reaching 2^36 bytes or 2^24 operations per key SHALL stop and mint a new generation. Consuming exhaustion MAY rebind the same epoch with bounded retry; repeated failure SHALL be visible, never trigger plaintext fallback.

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
