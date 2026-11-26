## MODIFIED Requirements

### Requirement: Relay tokens have one profile
<!-- base: d8ae45969131b7913a65d251bab79d612b3a40e3 openspec/specs/edge-relay/spec.md -->
The relay SHALL accept only a moq-auth JWT in the wire format of the pinned moq revision. Admission SHALL be the existing `assess` operation on one key-set snapshot: verification, `profile` (iat, exp, TTL, future iat, root), path containment when a session path is present, and grant validation. `KeySet::verify` alone is not admission. The relay SHALL NOT read a room-kind claim and SHALL NOT require one. A token carrying a claim outside that wire format, including `kind`, SHALL be refused. The token SHALL be signed with EdDSA or ES256 by a public key in the relay key file, named by the token's `kid`. It SHALL refuse a token that has no expiry, has no issue time, expires more than `:relay_token_max_ttl` (default 3600 seconds) after its issue time, grants neither publish nor subscribe, or whose root is not `t/<owner id>` or a path below it, where `<owner id>` is canonical per `Mjolnir.Deploy.Owner.parse/1`.

A root `t/<owner>/~open/<room>` is a longer tenant path under that rule. It is not a second profile. The relay SHALL admit it when the signature, time, and grant checks pass, and SHALL keep confining a room token to its signed root. A token rooted at `t/<owner>` MAY span both `t/<owner>/<room>` and `t/<owner>/~open/<room>` when its patterns do. Rejecting that wide credential on a WebRTC request is the edge's job (`add-webrtc-edge`), not a new relay rule.

#### Scenario: No expiry
- GIVEN a correctly signed token with no expiry
- WHEN it is presented
- THEN the session is refused

#### Scenario: Malformed owner
- GIVEN a correctly signed token whose root is `t/not-an-owner/a`
- WHEN it is presented
- THEN the session is refused

#### Scenario: Symmetric signature
- GIVEN a token signed with HS256
- WHEN it is presented
- THEN the session is refused

#### Scenario: Kind claim is still unknown
- GIVEN a correctly signed token carrying a claim `kind`
- WHEN it is presented to the current verifier
- THEN the session is refused

#### Scenario: Open root is a normal tenant path
- GIVEN a correctly signed room token whose root is `t/<owner>/~open/<room>` and whose grant covers that path
- WHEN it is presented on WebTransport to that path
- THEN the session is admitted
- AND the same token presented on `t/<owner>/<room>` is refused
