## MODIFIED Requirements

### Requirement: Relay tokens have one profile
<!-- base: d8ae45969131b7913a65d251bab79d612b3a40e3 openspec/specs/edge-relay/spec.md -->
The relay SHALL accept only a moq-auth JWT in the wire format of the pinned moq revision, with one addition: an optional top-level `kind` claim whose value is `open` or `protected` (`relay-room-auth`, "The relay reads the room kind claim"). The token SHALL be signed with EdDSA or ES256 by a public key in the relay key file, named by the token's `kid`. It SHALL refuse a token that has no expiry, has no issue time, expires more than `:relay_token_max_ttl` (default 3600 seconds) after its issue time, grants neither publish nor subscribe, or whose root is not `t/<owner id>` or a path below it, where `<owner id>` is canonical per `Mjolnir.Deploy.Owner.parse/1`. It SHALL refuse a token whose `kind` has any other value, a token carrying any other claim outside that wire format, and a token whose payload repeats a member or is not a JSON object.

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

#### Scenario: Kind claim
- GIVEN correctly signed tokens with no `kind`, with `"kind": "open"`, and with `"kind": "protected"`
- WHEN each is presented
- THEN each is admitted

#### Scenario: Unknown claim
- GIVEN a correctly signed token carrying a claim `foo`, with or without `kind`
- WHEN it is presented
- THEN the session is refused
