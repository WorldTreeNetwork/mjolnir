## ADDED Requirements

### Requirement: Content credentials never pass through Mjolnir
A relayed call SHALL protect media, catalogs and track names with profile `moq-e2ee-01-wip` under a content credential `{profile, kid, secret}` whose `context` is `mjolnir-call/v1/<owner id>/<room>`. The secret SHALL be 32 bytes from a cryptographically secure generator on the client that starts the call. Mjolnir SHALL NOT generate, receive, store, log or forward a content credential or usable key material derived from its secret. Opaque paths, physical track names and ciphertext MAY reach the relay as required by this profile. The room token minted by `Mjolnir.Relay.Mint` SHALL NOT change: root `t/<owner id>/<room>`, publish `[<label>/**]`, subscribe `[**]`. The relay SHALL NOT need code or configuration changes to carry a protected call.

#### Scenario: Mint request carries no credential
- GIVEN an owner starting an encrypted call
- WHEN their client mints a room token
- THEN the request body has at most `ttl`
- AND the mint log line and the relay log over the call contain neither the secret nor its base64url or hex encoding

#### Scenario: Room token alone does not read
- GIVEN a participant with a valid room token for the room and no content credential
- WHEN they subscribe to every announced broadcast and every semantic track name they can guess
- THEN each semantic name is `NotFound`
- AND any physical track they fetch yields only ciphertext that does not contain the publisher's plaintext

### Requirement: A protected broadcast sits under the participant label
A publisher SHALL announce a protected broadcast at `<label>/<opaque>/<epoch>` relative to the token root (Iroh: `t/<owner id>/<room>/<label>/<opaque>/<epoch>`). `<opaque>` SHALL be `credential.path(<label>)`. `<epoch>` SHALL be the canonical UUIDv7 text the publisher instance minted with `credential.produce()`. A subscriber SHALL take the epoch from the announced path, SHALL refuse a non-canonical epoch, and SHALL refuse a broadcast whose `<opaque>` is not `credential.path(<announced label>)`. Among several epochs under one label and opaque, a subscriber SHALL read the greatest and SHALL follow a newer one when it is announced. A client SHALL NOT fall back to plaintext in an encrypted room.

#### Scenario: Two credential holders
- GIVEN alice and bob in room R, each with a room token for their own label and the same content credential
- WHEN alice publishes video and a catalog
- THEN bob decrypts both
- AND the relay forwards only paths of the form `<label>/<22 base64url>/<UUIDv7>`

#### Scenario: A relay re-labels a broadcast
- GIVEN alice's broadcast at `alice/<path(alice)>/<epoch>`
- WHEN a subscriber is offered the same bytes under `bob/<path(alice)>/<epoch>`
- THEN the subscriber refuses it because `path(bob)` differs

### Requirement: Track names are opaque at the relay
Every semantic track and broadcast name SHALL reach the relay only as its `moq-e2ee` physical name or opaque segment. The shipped client SHALL keep every semantic track name at 15 bytes or less so that every physical name has the same length. Display names SHALL appear only inside the encrypted catalog.

#### Scenario: Capture at the relay
- GIVEN the relay running with its QUIC keylog and a capture of a two-client encrypted call
- WHEN the capture is decrypted with the relay's keys
- THEN no injected media marker, display name, or semantic track or broadcast name appears in it

### Requirement: Removing a member is a new credential
To remove a member, the remaining members SHALL receive a new credential with a greater `kid` and a fresh secret. Each remaining publisher SHALL announce a new broadcast under it on its open session, and SHALL then finish every track of the old broadcast and close that broadcast. Withdrawing the old route alone SHALL NOT count as removal. Each remaining subscriber SHALL follow the new broadcast without reopening its session.

#### Scenario: Carol is removed
- GIVEN alice, bob and carol reading under kid 1
- WHEN alice and bob receive kid 2 and alice republishes and ends her kid 1 broadcast
- THEN bob decrypts alice under kid 2 on the same session
- AND carol stops receiving alice's media
- AND carol, whose room token is still valid, gets `NotFound` for every semantic name under kid 2

### Requirement: The credential reaches a browser in the link fragment only
A browser guest SHALL receive the content credential and the room token in the URL fragment of the invite link. The page SHALL remove the fragment from the address bar and history on load. The page SHALL NOT send the secret or usable key material in any request URL, header or body. The room token SHALL go only to the intended relay admission endpoint; derived opaque paths, physical names and ciphertext MAY go to that relay. The page SHALL serve `Referrer-Policy: no-referrer`. A link without a secret SHALL NOT join in plaintext.

#### Scenario: Network log of a join
- GIVEN a browser opening an invite link and staying in the call for one minute
- WHEN its full network log is captured
- THEN no request URL, header or body contains the secret or the room token in any encoding, except the room token in the relay connection's `jwt` parameter

### Requirement: Publishers re-mint on a cloned image
A publisher SHALL mint a new generation for each process instance. A publisher in a Mjolnir guest SHALL mint a new generation when the VM generation id changes and SHALL NOT encrypt under the previous one after the change.

#### Scenario: Guest thaw
- GIVEN a guest publisher encrypting under epoch E
- WHEN the VM is snapshotted and thawed
- THEN the thawed publisher announces an epoch other than E before it writes another frame

### Requirement: Experimental profile is pinned across clients
Rust and browser adapters SHALL pin moq revision `4a6f52248` and profile `moq-e2ee-01-wip`. Invite links SHALL name the profile. Clients SHALL refuse unsupported profiles explicitly. Upgrades that change derivation SHALL require coordinated client upgrades and SHALL NOT require a relay change. Release checks SHALL run upstream vectors in Rust and JS and cross-language encryption/decryption and name derivation.

#### Scenario: A newer profile invite
- GIVEN a client implementing only `moq-e2ee-01-wip`
- WHEN it opens an invite naming another profile
- THEN it reports an unsupported profile and joins no plaintext broadcast
