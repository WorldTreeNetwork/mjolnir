# add-call-e2ee

> **PENDING** — contract revision after SEND-BACK. Architecture accepted by second advise; third-read diff check before product code.

Bead `mjolnir-rurh.9`, parent `mjolnir-rurh`, blocks browser-call-client `mjolnir-rurh.5`. Rigor: architecture. Preparation 2026-11-24: reconciled `b876a89` with second SEND-BACK `reviews/2026-11-24-advise-2.md` (ef9ce97), preserving the accepted B1–B6 architecture; scope remains contract only. `Fresh advise after preparation` stays open.

## Why

The relay terminates QUIC, so admission alone lets its host read media and catalogs. Protecting content at the endpoints removes that access from the relay and host processes. The browser origin serving executable code remains trusted, as Duke accepted on 2026-11-23 for this iteration; non-extractable keys mitigate export, not use or access to plaintext (`spikes/complete/logs/crypto-browsers.log`).

Upstream at moq `4a6f52248` says E2EE is “not ready yet” (`quest/m5/e2ee/README.md:11`). Finished `moq-e2ee-01` is decided but not landed at that pin; D7 records its incompatible derivation and API changes. `moq-e2ee-01-wip` is the validated development target, not an answer to which profile ships on by default.

## What

- Add `call-e2ee`: media, catalogs and semantic names are readable by content-credential holders against an actively untrusted relay/host, subject to the trusted browser origin and endpoint limits. Mjolnir never holds usable content keys. It sees owner/room/label, opaque/epoch, physical names, sizes, timing and public timestamps; timestamps are not authenticated.
- For `01-wip`, derive a credential per publisher label: context `mjolnir-call/v1/<owner>/<room>/<label>`, opaque `path("call")`, path `t/<owner>/<room>/<label>/<opaque>/<epoch>`. The old room-context/path(label) layout is rejected: claim 5a succeeds as an attack; 5b rejects it (`spikes/complete/logs/b1-relabel.log`).
- Reader tries candidates greatest first with a 1500 ms/authentication-failure fall-through and 12 new probes/label/rolling minute. Only an authentic frame advances the greatest-accepted mark, kept in page memory; announcements cannot poison it and accepted playback continues during probes. No automatic below-mark rendering. Publishers watch their own label and stop when another greater instance authenticates; explicit resume mints anew. This is scoped to this profile and revisited when upstream deletes Epoch ordering. The browser harness ran no instance-selection policy, only first-match discovery; this rule is unrun. Reload clears the mark/credential and needs the invite again; a fast-clock accepted publisher can strand a corrected-clock instance, shown as “newer stream expected, older one present”. A relay can still hide newer content/replay after reload.
- Pin one bridge surface for native and browser: protected `bridge.tracks` JSON snapshot with periodic refresh and duplicate-name suppression (D4). Both directions have real-media evidence, but the new manifest bounds/version/order/metadata-precedence rules are unrun. H.264 interoperability is a design limit, not an automatic presence rule: no native-reader presence signal exists; I2 precedes choosing an explicit codec policy. Chromium→native decode is logged but emitted codec is not, and native H.264-only support is source-derived. Catalog-only discovery is an unrun alternative, not the selected wire contract.
- Keep admission separate. Existing room tokens and mint remain unchanged; encryption prescribes content delivery, not how an admission token is delivered. Any token delivered in a link goes only to intended relay admission.
- A navigated invite fragment is scrubbed from the address bar and current session-history entry. It **persists in browser global history before page script runs**, including key/token; Chromium session files and segmentation_platform/ukm_db also retain it; off-device history sync and URL-keyed metrics remain unverified (`spikes/complete/logs/b3c-history-{chromium,firefox}.log`). Duke must accept disclosure in the page security note or choose non-navigation secret delivery.
- Removal issues a greater kid/new secret. On adopting it publishers announce then immediately retire old encryption, without waiting for subscribers; replacement delivery includes removedLabels, which adopting readers immediately stop rendering; for other labels old-key reading ends on their first new-kid authenticated instance. The owner defines observed completion by its locally issued replacement-label set, not disappeared announcements; no claim follows about old tabs. The publisher asserts no old-key seals after retire. Waiting readers lose retired publishers for the whole delivery delay. Chromium runs 1/2 recorded recovery after ~190 ms stall (scenarios passed; both exited code 2 because browser.close() did not return), with buffered tails and no guaranteed bound (`spikes/complete/logs/b-rekey-run{1,2}.log`). Same-session rekey assumes in-app credential delivery; a link guest's baseline is a replacement per-guest invite and rejoin. An open-page paste flow is recommended but unrun and awaiting Duke.
- The platform cannot record, transcode, transcribe, compose or preview protected calls without becoming a credential-holding endpoint. This is a permanent product consequence, not a later server feature.

## Impact

- ADDED capability `call-e2ee`; no modification to living `edge-relay` or `relay-room-auth`. No deployed relay code/configuration change or redeploy needed.
- Proposed ADR `docs/decisions/0017-call-e2ee.md` records decisions and future guest constraints. No guest thaw behavior is added by this spec.
- After review/activation: thin profile adapter in browser client, native helper/bridges and repeatable acceptance. Product code is not part of this revision. Crypto pins: moq `4a6f522483168ace392718d68b58a402533c897d`, iroh-live `747b1bd0567d2f6b019a89633c04e6561ccac460`.
- Acceptance uses a harness relay built from the same crate, with harness-only keylog; the shipped binary gets no runtime keylog switch. Captures check actual media content, not decoder exit codes (Opus decodes ciphertext as noise).

## User journey & surfaces

No new UI in this contract pass: the call page and invite/security-note controls belong to `mjolnir-rurh.5`.

An explicit owner CreateCredential action generates 32 fresh secret bytes; invites for that active call share secret/kid until rekey/end. The owner holds raw secret/invite text only in a private page-memory closure, guests hold memory-only handles, and leave/end discards obsolete application state. Reload loses both and joins nothing until the invite is supplied again. Whether a saved invite may intentionally be reused as a standing room link across calls is Duke's open ASK, recommendation one secret per call; no automatic cached reuse is allowed. The owner creates a per-guest invite. Content fields are `#v=1&p=<profile>&kid=<n>&k=<base64url secret>`; token delivery is independent. The page validates the profile/key, imports a non-extractable handle and scrubs the current URL/session-history entry. Working: holders see/hear; token-only readers see announcements and may fetch ciphertext but cannot recover the protected content. Missing key or unsupported profile: refuse with no plaintext fallback. A missing broadcast can mean wrong credential, expired admission or relay withholding; do not promise to distinguish them as “key no longer valid”.

Removal requires new credentials to every remaining publisher before their old publication can end. Until an open-page handoff is chosen/tested, remaining link guests receive individual replacement invites and rejoin. A missed/old tab may continue old-key publication: guests must close the old tab or use a tested same-origin stop signal owned by mjolnir-rurh.5. Owner-side observed completion requires authenticated new-kid instances for its replacement-recipient labels; it does not prove termination of every tab. Removed labels stop rendering immediately on adoption, regardless of token/broadcast expiry.

### Three admission/link limits (outside encryption)

- Invite lifetime is remaining token life from mint to exp, normally ≤3600 seconds under the operator ceiling; it does not restart when the link is opened.
- Only the owner can mint this room's tokens. A link guest cannot renew, and its call ends at exp. Continuity beyond one token needs owner refresh or a future delegated-invite change.
- A link carries one publish label. Forwarding shares that label; it does not create a second participant, and instance selection shows only one stream.

`mjolnir-rurh.5` owns the initial guest experience, per-guest links, lifetime messaging, replacement-flow choice and history security note, within `relay-room-auth`'s mint/expiry rules. No delegated-invite change is currently named; broader renewal requires new scoped work. ASK boxes carry lifetime, invite delivery and replacement delivery choices with recommendations.

## Out of scope

- Sender authentication among credential holders, forward secrecy and post-compromise recovery. The relay and a colluding holder can impersonate. MLS is a future credential-distribution seam, not implemented here.
- Padding/traffic analysis; timestamps, group truncation, replay and liveness/freshness guarantees remain limits (design D6).
- Early per-member token revocation; metadata/ciphertext access continues to exp. Content retirement and admission expiry are distinct.
- Guest publishers or readers outside the host trust boundary; future snapshot constraints are ADR-only.
- Peer fan-out and bandwidth savings; this relay still pays central egress. Coopbase/FOKS delivery is separate work.
