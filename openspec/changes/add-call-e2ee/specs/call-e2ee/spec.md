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
For `moq-e2ee-01-wip`, a publisher SHALL announce `<label>/<opaque>/<epoch>` relative to the room root (Iroh absolute `t/<owner>/<room>/<label>/<opaque>/<epoch>`), with opaque equal to the label-context credential's `path("call")` and epoch the canonical UUIDv7 minted by produce(). A receiver SHALL validate segments and opaque and try candidate epochs greatest first. The first authentic `bridge.tracks` frame under the label-context credential SHALL accept an instance; manifest schema validation SHALL still precede applying its snapshot. An announcement alone SHALL NOT advance the mark. The receiver SHALL retain the greatest accepted epoch per credential/kid/label only in page memory for that page's lifetime. The 1500 ms candidate deadline SHALL start with subscription to `bridge.tracks`. Authentication failure SHALL bar that candidate for the rolling 60-second window; a timeout alone SHALL NOT bar it. Either outcome SHALL fall through to a candidate at or above the mark while keeping accepted playback. A manifest subscription that the transport ends before an authentic frame SHALL count as a timeout. A timed-out candidate SHALL be retried with backoff starting at 3 seconds, doubling on successive timeouts and capped at 60 seconds. A transport end of the accepted instance SHALL NOT retract its announcement; only the relay's withdrawal does. A close of the accepted subscription within 10 seconds of its acceptance is rapid. The first close SHALL allow an immediate reconnect to the same epoch; each further consecutive rapid close SHALL delay re-probing that epoch by 3 seconds, doubling and capped at 60 seconds; a session that lasted 10 seconds or longer SHALL reset the count to zero, so the next rapid close again reconnects immediately. This delay SHALL apply to that epoch only: higher eligible epochs and the probe budget are independent of it. An authentication failure SHALL bar a candidate only when reported for a probe the reader actually started, within 60 seconds of that probe's start, whether or not the probe is still live; the bar SHALL NOT depend on the order of clock advances or on forgetting a withdrawn record. Each probe SHALL report at most one failure; a repeated report SHALL be refused and SHALL NOT extend the bar. A later authenticated acceptance of the same epoch SHALL clear a bar set by an earlier attempt of that epoch and SHALL refuse that earlier attempt's failure reports from then on, including after the later session ends; an authenticated open is stronger evidence than a late report. A failure from an earlier attempt while its replacement is only probing still bars. Every probe, including a retry, SHALL count toward at most 12 attempts per label per rolling 60 seconds, one at a time. Exhausting this budget SHALL expose `unavailable_retryable` without clearing the mark/accepted stream. It SHALL NOT render a below-mark instance automatically; when only older instances remain it SHALL expose `older_stream_only`. Reload SHALL discard the mark. A publisher SHALL watch its own label using the same authentication rule; when another greater instance authenticates it SHALL stop its own publication and expose `superseded_by_another_instance`. Resuming on that device by explicit user action SHALL mint a new generation. No encrypted room SHALL fall back to plaintext. Reader memory per credential/kid/label SHALL be bounded: at most 256 candidate records (announcements and refusal tombstones); a full table SHALL first forget a below-mark record to admit an epoch at or above the mark, SHALL otherwise be reported distinctly from an invalid path, and the adapter SHALL offer still-active announcements again; a full refusal, or forgetting an active record to make room, makes the reader's candidate view incomplete until the adapter reconciles the authoritative active set (see adapter states). At most 128 distinct track names per accepted instance; a further name SHALL be refused with track-scoped `unavailable_retryable`, and no existing track's mark SHALL be dropped to make room. No counter SHALL be kept for a track name the reader never subscribed. These bounds limit work, not a relay's power to deny service.

An authentication failure on a track inside an accepted instance SHALL NOT un-accept the instance or bar its epoch as a candidate. At this pin the failure ends that subscription. The reader SHALL resubscribe that track on the **same consuming generation**, keeping its group/frame mark and local mirror, at most 6 resubscriptions per track per rolling 60 seconds. After that it SHALL expose `unavailable_retryable` for that track with the time a retry is allowed; retries SHALL respect the budget. A track subscription's terminal failure SHALL retire that subscription's handle at once, in both cases, so a later frame or failure on it is refused; the replacement or the clocked retry after exhaustion gets a new handle and keeps the mark, mirror and budget. This path SHALL NOT rebind the generation to reset its failed-open budget. When the accepted instance ends and the same epoch is accepted again, the reader SHALL reuse the same consuming generation and SHALL keep that epoch's group/frame marks, mirrors and resubscription budgets; they are released only when a greater epoch is accepted.

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
- WHEN its manifest subscription fails authentication or times out within 1500 ms of subscription
- THEN it does not advance the mark and the reader tries the real candidate within the per-label attempt budget
- AND a currently accepted stream keeps playing
- AND a timeout is retried after backoff starting at 3 seconds, with every retry counted in the 12-attempt budget; only an authentication failure bars the candidate

#### Scenario: Second device under one label
- GIVEN a laptop publishes E1 and a phone using the same invite publishes greater E2
- WHEN an E2 frame authenticates at the laptop and other readers
- THEN readers mark E2 and the laptop stops E1 publication and exposes `superseded_by_another_instance`
- AND an explicit resume action on the laptop mints a new generation, rather than resuming E1 counters

#### Scenario: Reload is a fresh reader
- GIVEN the page accepted E2 and scrubbed its invite URL
- WHEN the page reloads
- THEN no instance mark or credential is restored from application storage and the adapter exposes `invite_needed`
- AND after re-entry it is a fresh reader with no persisted E2 mark


### Requirement: One confidential bridge wire surface
Both bridges SHALL carry one protected track per semantic local track, including catalogs, plus a protected `bridge.tracks` manifest. Each manifest group SHALL contain one JSON frame mapping semantic names to `{timescale: units/s|null, maxAgeMs: number|null, priority: i8}`. Publishers SHALL send a complete current snapshot on track-set changes and refresh it every second while live. Receivers SHALL derive physical names from manifest entries and the consuming generation; authenticated manifest metadata SHALL be authoritative for local tracks. Relay-supplied TRACK_INFO SHALL NOT be substituted for manifest values; a difference SHALL be reported through `metadata_difference`, without rejecting the track solely for that difference. Publishers SHALL suppress duplicate track listings within a generation rather than recreate a protected track with the same name. Semantic names SHALL be at most 15 UTF-8 bytes; display names SHALL be encrypted. Plaintext local origins SHALL never be attached to a relay session, including stats/echo paths.

For invite `v=1` and context `mjolnir-call/v1/...`, the manifest SHALL use exactly this map shape; unsupported invite/context versions SHALL be refused. Before creating subscriptions the reader SHALL reject an entire snapshot exceeding 16 KiB of UTF-8 JSON or 32 entries, duplicate keys, empty/non-string names, names longer than 15 UTF-8 bytes, non-object entries, extra metadata fields, or invalid values. Timescale SHALL be null or a positive safe integer; maxAgeMs SHALL be null or a finite nonnegative safe integer; priority SHALL be an integer in [-128,127]. A snapshot SHALL be applied atomically only after authentication and validation, with one frame per group and a group start strictly greater than the last applied manifest group for this kid/label/epoch. Older or duplicate groups and their late frames SHALL NOT replace newer metadata. The reader SHALL NOT partially apply an invalid snapshot.

#### Scenario: Bounded and ordered manifest
- GIVEN a valid authenticated v1 snapshot from group G has been applied
- WHEN an oversized snapshot, invalid metadata, duplicate keys, or an authenticated snapshot at or below G arrives
- THEN subscriptions and metadata do not change
- AND a valid greater snapshot uses its authenticated metadata, reporting a TRACK_INFO difference without substituting relay values or rejecting the track solely for it


#### Scenario: Late reader and re-listed audio
- GIVEN either bridge has added audio after its initial manifest
- WHEN a reader subscribes late and the source lists an existing track again
- THEN periodic manifest snapshots include audio and the reader derives its physical name
- AND the publisher retains the existing protected track without a duplicate-name failure

### Requirement: Removal retires old publication immediately
The owner SHALL deliver a replacement credential with a greater kid, fresh secret and a canonical `removedLabels` list covering every label removed since CreateCredential, including removals missed by this recipient. The v1 invite field SHALL be `removedLabels=<unpadded base64url of a UTF-8 JSON array of canonical labels>`, at most 4096 encoded ASCII characters and at most 32 unique entries; invalid encoding, duplicate/noncanonical labels or overflow SHALL be refused, never truncated. An initial invite MAY omit the field to mean empty; every replacement SHALL include it. A reader adopting it SHALL immediately stop rendering/unsubscribe removed labels, including buffered old media. For every other label it MAY retain an old credential read-only only until that label has an accepted/authenticated instance under the new kid or 10 minutes from adoption, whichever occurs first; it SHALL then stop that label's old subscriptions and discard its old consuming handles. The retention timer SHALL use elapsed page time and SHALL NOT be extended for the same old credential by later replacements. On retention expiry without new-key media the adapter SHALL expose `waiting_for_new_key`. During retention, a removed member with the relay's help can forge old-key media of a retained label; the time bound limits that exposure, not the forgery itself. It SHALL discard the old credential handle when no retained labels need it, or on leave/reload. Old credentials SHALL NOT be used to produce after adoption.

A remaining publisher SHALL mint and announce a new generation, then immediately stop old-generation sealing, finish old tracks and close the old broadcast without waiting for reader acknowledgements. Withdraw alone SHALL NOT count as retirement. Same-session switching applies only to clients supplied the replacement credential in-app; replacement invitation and rejoin remain the link-guest baseline. The adapter SHALL expose `close_old_tab` on rejoin unless a tested same-origin stop mechanism retires the old tab. Owner-side completion SHALL mean every label in the owner's locally maintained set of replacement recipients has an accepted/authenticated instance under the new kid; it SHALL expose missing labels as `removal_pending`, not infer completion from absent old announcements. A recipient that never publishes cannot supply an accepted instance and SHALL stay `removal_pending` with reason `nonpublishing_unobservable`, not be treated as a failed publication. If reload loses the owner's removal-cycle recipient set, the adapter SHALL expose `removal_completion_unknown` until that set is re-established by the owner, never inferred from relay announcements. This observation does not attest termination of other tabs. Buffered and recorded content cannot be recalled.

#### Scenario: Removed member and slow hand-out
- GIVEN carol retains the old key/token and continues her own old broadcast
- WHEN bob adopts a replacement listing carol as removed
- THEN bob stops rendering carol immediately even if her old broadcast never ends
- AND bob may read another non-removed label with the old key only until its new-kid instance authenticates or 10 minutes elapse from adoption
- AND a reader skipping an intermediate replacement still stops every label removed since CreateCredential

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
A link-delivered content credential SHALL be confined to its URL fragment, imported into a non-extractable HKDF handle after length validation, and removed from the address bar and current session-history entry on page load. The page SHALL NOT claim this erases persistent/global history or browser session files: both tested browsers persist the navigated invite before page script runs. The page SHALL NOT send the secret or usable keys in HTTP requests or error reports, or persist raw secret material in application storage. Guest handles SHALL remain in page memory only. The owner's secret/invite copy for later invitations SHALL live only in a private page-memory closure, not persistent storage. Leave, call-end or replacement SHALL discard obsolete application references, apart from read-only consuming handles allowed above; reload SHALL lose the current credential/owner copy, join nothing and expose `invite_needed`. A new call without a retained external invite SHALL create a new credential, not recover from application storage. If an admission token is delivered in a link, it SHALL go only to intended relay admission, not other requests/reports. Derived opaque protocol data MAY go to the relay. The page SHALL serve Referrer-Policy no-referrer and no third-party scripts.

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
For each protected track/kid/label/epoch, the reader SHALL keep a page-memory mark comprising group start and last authenticated frame index. Authentication SHALL advance that pair; manifest snapshot application SHALL additionally require validation. Re-offering the equal group SHALL continue only at frame indices strictly above its last authenticated index; indices at or below it SHALL NOT reopen. The local mirror of the track SHALL live as long as its mark, and resubscription SHALL reset neither; nor SHALL ending and re-accepting the same epoch. Zero reorder allowance SHALL apply to manifest and catalog tracks: older groups SHALL NOT roll back their mirrored state. A non-authenticating high group/frame SHALL NOT advance the mark. A replay to a fresh reader or never-seen delayed content remains outside this protection.

Media tracks SHALL use a window of remembered authenticated group starts and last frame indices behind the newest authenticated group start. The window is a reader parameter. Its value is **provisionally 120 ms**, to be confirmed or revised by C2's integrated run under real network impairment; until then 120 ms is not a settled requirement. A start strictly more than the window behind SHALL be refused; already authenticated frame indices SHALL never be reopened. The group-start span SHALL be converted using the authenticated manifest timescale, never relay TRACK_INFO. Zero reorder remains for manifest and catalog. A track SHALL remember at most 128 group starts; evicting the oldest SHALL raise an irreversible floor at or below which every start is refused, so the bound fails closed. Decision evidence: `spikes/complete/logs/i8-shaper.log` (userspace reliable-delivery/jitter model, not a physical-network guarantee): 9000/9000 audio frames delivered at 120 ms versus 7194/9000 at zero; at most seven remembered starts for 20 ms Opus groups. Integration/playback under real network impairment remains C2 validation. The same model against the C1 tracker delivers 8873/9000 at 150 ms and 8821/9000 at 250 ms retransmission delay (`reviews/2026-11-24-c1-code-review.md`), so the window stops helping once retransmission exceeds about 100 ms.

#### Scenario: Replay and failure inside an accepted instance
- GIVEN an accepted instance whose track has authenticated group G2 after G1
- WHEN a relay replays already opened frames with current public timestamps or supplies a bad frame in the accepted track
- THEN already authenticated frame indices are not reopened and the bad frame advances no mark
- AND the instance remains accepted; the reader resubscribes that track on the same consuming generation with its mark and mirror kept, at most 6 times per track per 60 seconds, then exposes `unavailable_retryable`
- AND an older manifest/catalog group cannot roll back mirrored state

#### Scenario: Equal group resumes after resubscription
- GIVEN the catalog or video mirror contains frames through authenticated index F in group G
- WHEN resubscription offers G again starting at an index above F
- THEN only authenticated frames strictly above F continue into the existing mirror
- AND neither the mark nor mirror is reset, so a long-lived catalog group need not wait for another group

### Requirement: Adapter states are surfaced by the page
The adapter SHALL expose `superseded_by_another_instance`, `older_stream_only`, `unavailable_retryable`, `metadata_difference`, `invite_needed` and `close_old_tab` with affected label/track scope where applicable. For one label, playback, supersession, candidate probing and older-stream facts SHALL be reported side by side, never as one value that a later report replaces: budget exhaustion SHALL expose `unavailable_retryable` for candidate probing beside, not instead of, an accepted stream's `ready` or `superseded_by_another_instance`. `superseded_by_another_instance` SHALL hold while the accepted epoch is greater than the device's own publishing epoch, including immediately after a resume. `older_stream_only` SHALL hold exactly when nothing is accepted, no announced candidate is at or above the mark, at least one announced candidate is below it, and the candidate view is complete. Budget exhaustion SHALL be reported even while the last probe is live. The reader SHALL report first acceptance of an instance (including re-acceptance of the same epoch) distinctly from a manifest refresh of the accepted one. Every callback the adapter reports SHALL carry the identity of the one subscription it came from. Starting a manifest subscription returns an opaque subscription handle; starting a track subscription of the accepted session returns a track handle. Acceptance, refresh, a probe's end, a candidate failure, the accepted session's end, track registration, track failure and every frame and mirror update SHALL present that handle, and the reader SHALL refuse (`stale`, ignored or `false`) a handle that is not the live probe, the accepted session, or that track's current subscription. A late event from an earlier attempt of the same epoch SHALL NOT act on its replacement, while same-epoch marks, mirrors and budgets carry across attempts. C2 holds these handles alongside the subscriptions it opens. A handle carries authority only as the exact reference the reader issued; copies, clones and another reader's handles are refused. Malformed, wrong-type or unknown arguments SHALL be refused before any state changes. The adapter SHALL apply a frame to its mirror in the same synchronous step as the reader's `deliver` decision, or check the handle is still current at the mirror if work yielded in between. After a `full` refusal or a session reconnect the adapter SHALL call reconcile with the complete active announcement set for the label (an empty set is a valid answer); only a reconciliation in which every active epoch fits makes the candidate view complete, and an admission, a duplicate or a partial reconciliation does not. It SHALL also expose `waiting_for_new_key`, `removal_pending` and `removal_completion_unknown` for the retention/completion rules. The browser page SHALL surface these adapter states; page wording belongs to `mjolnir-rurh.5` rather than this adapter contract.

#### Scenario: State rather than page copy
- GIVEN the adapter has no credential after reload or observes a metadata difference
- WHEN it reports the outcome
- THEN it exposes `invite_needed` or `metadata_difference` with relevant scope
- AND the page surfaces that state without requiring a particular sentence from the adapter


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
