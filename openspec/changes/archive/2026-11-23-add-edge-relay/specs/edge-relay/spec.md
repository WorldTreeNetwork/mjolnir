## ADDED Requirements

### Requirement: Only the relay deploy changes the relay's state
`deploy.sh --relay` SHALL be the only operation that installs, updates, starts, stops or removes `mjolnir-relay` and its firewall rule. With `:relay_enabled` true and `:relay_host` set it SHALL install and start the unit. With `:relay_enabled` false or `:relay_host` unset it SHALL stop the unit, remove it, and remove the relay's firewall rule. Every other deploy and every restart of `mjolnir` or `mjolnir-gateway` SHALL leave the unit, its sessions and its firewall rule as they were.

#### Scenario: A host with the relay not enabled
- GIVEN a host where `:relay_enabled` is unset and the relay was never installed
- WHEN any deploy runs, including `deploy.sh --relay`
- THEN no `mjolnir-relay` unit exists
- AND no firewall rule tagged `mjolnir-relay` exists

#### Scenario: First enable
- GIVEN a host where the relay was never installed, `:relay_enabled` true, `:relay_host` set, and a usable certificate and key file
- WHEN `deploy.sh --relay` runs
- THEN `mjolnir-relay` is active
- AND one rule tagged `mjolnir-relay` exists
- AND the process ids of `mjolnir` and `mjolnir-gateway` are the same as before

#### Scenario: Enabled, then disabled
- GIVEN a running relay
- WHEN `:relay_enabled` is set false and `deploy.sh --relay` runs
- THEN the unit is stopped and removed
- AND the process holds neither its UDP 443 socket nor its Iroh endpoint
- AND the rule tagged `mjolnir-relay` is gone
- AND rules tagged for published guest ports are unchanged

#### Scenario: Disable twice
- GIVEN a host where the relay was already removed
- WHEN `deploy.sh --relay` runs with the relay disabled
- THEN it exits zero and changes nothing

#### Scenario: Flag cleared, other deploy
- GIVEN a running relay and `:relay_enabled` since set false
- WHEN a gateway or controller deploy runs
- THEN the relay is still running and its sessions are open

#### Scenario: Gateway restart during a call
- GIVEN a browser playing a broadcast through the relay
- WHEN `mjolnir-gateway` restarts
- THEN playback continues

### Requirement: A failed enable opens nothing
The relay's firewall rule SHALL be one input rule for UDP 443 tagged `mjolnir-relay`, added only after the unit is active. If the unit does not become active, `deploy.sh --relay` SHALL exit non-zero, leave the unit failed, and add no rule. The relay SHALL NOT stop or replace another process that holds UDP 443.

#### Scenario: No certificate at enable
- GIVEN no usable certificate for `:relay_host`
- WHEN `deploy.sh --relay` runs with the relay enabled
- THEN it exits non-zero
- AND `systemctl is-failed mjolnir-relay` is true
- AND no rule tagged `mjolnir-relay` exists

#### Scenario: Port already held
- GIVEN another process bound to UDP 443
- WHEN the relay starts
- THEN the relay exits non-zero and that process is still running

### Requirement: Stopping drains for a bounded time
On SIGTERM the relay SHALL at once refuse new sessions on WebTransport and on Iroh, keep existing sessions for at most `:relay_drain_seconds` (default 30), then close the rest and exit. The unit's stop timeout SHALL be longer than the drain.

#### Scenario: Stop during a call
- GIVEN one session playing a broadcast
- WHEN the unit is stopped
- THEN a new session attempted one second later is refused
- AND the process has exited within `:relay_drain_seconds` plus ten seconds

### Requirement: The relay serves a certificate valid for its name
The relay SHALL serve WebTransport on UDP 443 with a certificate whose chain parses, whose key matches, which names `:relay_host`, and which is inside its validity period. It SHALL NOT generate a certificate. It SHALL NOT start without such a pair. When the certificate it is serving passes `notAfter`, it SHALL exit non-zero.

#### Scenario: A browser connects by name
- GIVEN the relay running with an issued certificate for `relay.example.net`
- WHEN a browser opens a WebTransport session to `https://relay.example.net/`
- THEN the TLS handshake completes with no certificate hash supplied by the page

#### Scenario: No certificate
- GIVEN no certificate pair for `:relay_host`
- WHEN the unit starts
- THEN it exits non-zero and names the file it could not use

#### Scenario: Certificate expires while running
- GIVEN a running relay whose certificate was not renewed
- WHEN the certificate's `notAfter` passes
- THEN the unit is failed
- AND a restart fails for the same reason

### Requirement: The relay's private key is private where it is issued
The issuer SHALL write the `:relay_host` pair only into a directory of its own that is owned by the issuer's user with no access for group or others, and that holds no other subject. It SHALL create every file there, temporary files included, with no access for group or others from creation. If it cannot establish that directory and those modes it SHALL fail before any key byte is written. Only the issuer's user and root can read the source key.

#### Scenario: Key being staged at the source
- GIVEN an issuance for `:relay_host` paused after its temporary key file is created
- WHEN `nobody` and the relay's user try to read that file
- THEN both reads are denied

#### Scenario: Source directory cannot be made private
- GIVEN the issuer's relay directory exists with group or other access that the issuer cannot remove
- WHEN issuance runs
- THEN it exits non-zero and no key file exists there

### Requirement: The relay cannot redirect the copy
Every directory from `/` to `/var/lib/mjolnir-relay/tls/` SHALL be owned by root and writable by root only. The relay's own writable state SHALL live outside that tree. The copy step SHALL refuse to run, and SHALL write nothing, if any component of the destination path is a symbolic link, is not owned by root, or is writable by another user.

#### Scenario: Replaced parent
- GIVEN `/var/lib/mjolnir-relay` replaced by a symbolic link, or made writable by the relay's user
- WHEN the copy step runs
- THEN it exits non-zero
- AND no key byte was written anywhere

### Requirement: The relay's key pair is copied by root, whole and private
A root-owned step SHALL copy only the `:relay_host` certificate and key into `/var/lib/mjolnir-relay/tls/`. That directory SHALL be owned by root, readable by the relay's group, and writable by root only. Each copy SHALL be a new generation directory created with no access for other users before any key byte is written. The step SHALL check that the key matches the leaf, the leaf names `:relay_host` and the pair is in its validity period, and only then point `current` at the new generation by one rename. On any failure it SHALL leave `current` as it was and exit non-zero. It SHALL NOT copy the ACME account key, another subject's key, or any edge-auth key.

#### Scenario: Unrelated service user
- GIVEN an installed pair
- WHEN the `mjolnir` user or `nobody` reads `/var/lib/mjolnir-relay/tls/current/key.pem`
- THEN the read is denied

#### Scenario: Key being staged at the destination
- GIVEN a copy paused after its generation directory is created and before `current` moves
- WHEN `nobody` reads the key in that generation directory
- THEN the read is denied

#### Scenario: Copy fails part way
- GIVEN a copy that fails after the certificate is written and before the key is
- WHEN the step exits
- THEN it exits non-zero and `current` still names the previous generation

#### Scenario: Mismatched pair
- GIVEN a renewed certificate whose key file is from the previous issue
- WHEN the copy step runs
- THEN it exits non-zero
- AND `current` still names the previous generation

#### Scenario: Renewal
- GIVEN a running relay and a renewed pair
- WHEN the copy step succeeds
- THEN a session opened after the step returns is served the new certificate

### Requirement: The relay name adds no site or route
`:relay_host` SHALL be a certificate subject only. Issuing or renewing it SHALL add no `[[domain]]`, no route and no apex, SHALL NOT be reachable through a public issuance or listing API, and SHALL NOT return PEM through any API.

#### Scenario: Renewal of the relay name
- GIVEN the relay name due for renewal
- WHEN renewal runs
- THEN the gateway's routing configuration is byte-identical before and after

### Requirement: Relay tokens have one profile
The relay SHALL accept only a moq-auth JWT in the wire format of the pinned moq revision, signed with EdDSA or ES256 by a public key in the relay key file. It SHALL refuse a token that has no expiry, has no issue time, expires more than `:relay_token_max_ttl` (default 3600 seconds) after its issue time, grants neither publish nor subscribe, or whose root is not `t/<owner id>` or a path below it, where `<owner id>` is canonical per `Mjolnir.Deploy.Owner.parse/1`.

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

### Requirement: Relay keys are used for nothing else
The relay key file SHALL hold public keys only, and only keys whose private half signs relay tokens. No edge-auth login key, IdentiKey signing key or biscuit root SHALL appear in it. The relay SHALL hold no private signing key. A credential of another profile SHALL be refused.

### Requirement: A signing key belongs to one relay
A relay's audience SHALL be its `:relay_host`. A key that signs relay tokens SHALL be trusted by the key file of exactly one `:relay_host`. A token signed for another relay SHALL be refused, on WebTransport and on Iroh.

#### Scenario: Token for another relay
- GIVEN relay A trusting key Ka, and a token signed by Kb, which only relay B trusts, with an otherwise valid root, grant and expiry
- WHEN the token is presented to relay A by a browser, and by an Iroh client
- THEN both sessions are refused
- AND the same claims signed by Ka are admitted

#### Scenario: Login credential
- GIVEN a valid IdentiKey access token or edge-auth session credential
- WHEN it is presented to the relay
- THEN the session is refused

### Requirement: Every session needs a token, and identity alone grants nothing
The relay SHALL refuse a WebTransport session or an Iroh session that presents no token, a token it cannot verify, an expired or not-yet-valid token, or a token whose grant does not cover the requested path. An Iroh endpoint id SHALL grant nothing by itself. A refused session SHALL receive no announcement and no catalog.

#### Scenario: No token, either transport
- GIVEN a broadcast published at `t/<owner>/a/b`
- WHEN a browser, or an Iroh client, opens a session to that path with no token
- THEN the session is refused with no announcement and no catalog

#### Scenario: Iroh publisher with no token
- GIVEN an Iroh client with endpoint id E and no token
- WHEN it publishes at any path, including one that names E
- THEN the publish is refused

### Requirement: A token's rights bound the whole session
For the life of a session the relay SHALL allow a publish only at paths the token's publish patterns cover, and a subscribe or announcement only at paths its subscribe patterns cover. Path matching SHALL be by whole segment. A path with an empty, `.` or `..` segment SHALL be refused. At the token's expiry the relay SHALL close the session.

#### Scenario: Subscribe-only token publishes
- GIVEN a token that grants subscribe under `t/<owner>/a/` and no publish
- WHEN its holder publishes at `t/<owner>/a/b`
- THEN the publish is refused

#### Scenario: Another tenant
- GIVEN a token rooted at `t/<owner1>/`
- WHEN its holder asks for a path under `t/<owner2>/`
- THEN the request is refused

#### Scenario: Sibling prefix
- GIVEN a token rooted at `t/<owner>/a`
- WHEN its holder asks for `t/<owner>/ab/c` or `t/<owner>/a/../x`
- THEN the request is refused

#### Scenario: Announcements outside the grant
- GIVEN broadcasts at `t/<owner>/a/b` and `t/<owner>/z/y`, and a token that grants subscribe under `t/<owner>/a/`
- WHEN its holder asks for announcements
- THEN it is told of `a/b` and not of `z/y`

#### Scenario: Valid narrow grant
- GIVEN a token that grants publish at `t/<owner>/a/b` and subscribe under `t/<owner>/a/`
- WHEN its holder publishes `a/b` and another holder with subscribe under `t/<owner>/a/` subscribes to it
- THEN media is delivered

#### Scenario: Expiry during a session
- GIVEN a session admitted with a token that expires in ten seconds
- WHEN fifteen seconds have passed
- THEN the session is closed

### Requirement: Key changes are atomic, fail closed and acknowledged
The relay key file SHALL be `/etc/mjolnir-relay/relay-keys.json` and the relay environment file SHALL be `/etc/mjolnir-relay/relay.env`. That directory SHALL be owned by root and SHALL NOT be writable by group or other. The key file SHALL be owned by root and not writable by the relay's user, and SHALL be replaced by rename. At start, a missing, empty or malformed file, a file whose directory is writable by anyone but root, or one holding a symmetric or private key, SHALL make the unit fail. After a rename the relay SHALL, within five seconds, either use exactly the new set for new sessions and write that file's SHA-256 to `/run/mjolnir-relay/keys.active`, or, if the new file is not usable, refuse every new session and write `invalid` there. Existing sessions keep their admission until their token expires.

#### Scenario: Key removed
- GIVEN a session admitted with a token signed by key K
- WHEN a file without K is renamed into place and `keys.active` shows its hash
- THEN a new session with a token signed by K is refused
- AND the relay process did not restart

#### Scenario: Malformed replacement
- GIVEN a running relay
- WHEN a malformed file is renamed into place
- THEN `keys.active` reads `invalid` within five seconds
- AND a new session with a token signed by a previously valid key is refused

#### Scenario: Missing at start
- GIVEN no key file
- WHEN the unit starts
- THEN it exits non-zero

### Requirement: Broadcasts live under a tenant prefix
The relay SHALL accept a publish only at a path that begins `t/<owner id>/`.

#### Scenario: Publish outside the prefix
- GIVEN any token
- WHEN its holder publishes at `live/x`
- THEN the publish is refused

### Requirement: The relay does not dial out for a client
The relay SHALL NOT open an Iroh connection because a session named a ticket or an endpoint.

#### Scenario: A session names a ticket
- GIVEN a valid token
- WHEN a session's path is a broadcast ticket
- THEN the session is refused
- AND the relay opened no outbound Iroh connection
