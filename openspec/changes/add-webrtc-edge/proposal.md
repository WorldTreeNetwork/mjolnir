# add-webrtc-edge

> **PENDING**

Node `mjolnir-rurh.13`. Rigor: architecture. Depends on `.11`'s accepted path rules and, as a whole node, on `.12`. Duke's 2026-11-25 steer is one relay connection per token. This revision follows that steer. The 2026-11-26 build grant is already recorded. Product code waits for a fresh accept of this text. Production install stays a separate approval.

ADR draft: [`docs/decisions/0020-webrtc-edge.md`](../../../docs/decisions/0020-webrtc-edge.md).

## Why

The spike admits a bearer and opens one relay connection per WHIP or WHEP call. That contradicts the recorded steer, checks only the last room segment, and leaves DELETE unauthenticated. `assess` (`native/mjolnir_relay/src/lib.rs`) returns `Result<Grant, Refuse>` and does not load keys. `RoomJoin` is not this process.

## What

- **Connection.** Exact token bytes → one relay connection. Refcount of live sessions. Last release closes it. Expiry or relay closure closes it and every session on it. A new token never joins an old connection. A new operation still runs full admission; a live connection is not a waiver.
- **Admission.** `load_verify_keys` rules, configured `max_ttl` (the relay ceiling, not a hardcoded spike constant), one snapshot of key set plus availability. Then open-root classification, URL room segment, byte-exact `X-Mjolnir-Root`, grant match. Wide roots refused. TLS to the relay verifies the certificate. Insecure verification is not a product default.
- **Preflight.** `POST /admit` runs that admission and does not dial the relay or build SDP. WHIP and WHEP run it again.
- **Setup transaction.** Bound by `exp` and a 5 s setup timeout (the pin's catalog wait). Recheck `exp` immediately before `201`. On refusal, timeout, relay close, or failure to write the answer, drop the unrun `Response` and any hold on the connection. A `409` leaves no registered session.
- **DELETE.** `DELETE /session/<id>` with the same bearer that admitted it. `204` if this token owns it, including a repeat after it is gone. `404` unknown. `403` if another token presents it. Cleanup of one id does not close another leg's WebRTC session. If the refcount hits zero, the connection closes.
- **HTTP.** Configured page origins, else same origin. Methods POST, DELETE, OPTIONS. Request headers `Content-Type`, `Authorization`, `X-Mjolnir-Root`. Response exposes `Location`. No credentialed redirect. JSON `{"error":"<code>"}`.
- **Codec.** Inspect the answer `moq_webrtc` built. If video was offered and the answer rejects every video m-line, drop the unrun response and return `409 codec_unavailable`. Before expiry, WHEP with no catalog, catalog timeout, or no rendition: `409 not_started`; expiry takes precedence as `403 bad_token` (design D8). WHIP has no source catalog to require.

## Impact

- Capabilities: ADDED `webrtc-edge` (gateway requirements in this change; keyframe requirements in `.12`).
- ADR 0020 is the draft above. It is not accepted by being committed.
- Code after accept: the binary, unit, and tests. No production flag run.

## User journey & surfaces

No new page because `.15` owns the page. This node is the HTTPS origin that page is configured to trust.

- **Working:** open token, matching expected root, grant matches, catalog overlaps. `201`, `Location: /session/<id>`, media through the relay.
- **Refused before dial:** see the status table in the design. No SDP body.
- **Expired during setup:** no `201`. Candidate resources dropped. All same-token legs stop; other-token legs stay up. A setup timeout strictly before expiry drops only the candidate and preserves same-token incumbents.
- **Off:** unit not installed.

## Out of scope

- Roster (`.14`). Viewer PLI and in-process WHEP (withdrawn on `.12`).
- TURN, firewall, production hostname.
- Claiming per-owner quotas that `.4` has not shipped.
- Ubuntu 24.04 as if the Arch claim-8 log were that build. Ubuntu remains an implementation gate. Claim 8 is Arch x86_64, toolchain 1.95.0, no Node (`spikes/logs/claim8-linux.log`).
