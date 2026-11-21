## ADDED Requirements

### Requirement: The relay is off unless the host enables it
The system SHALL install and start `mjolnir-relay` only when `:relay_enabled` is true and `:relay_host` is set. Otherwise no process listens on UDP 443.

#### Scenario: A host that did not enable it
- GIVEN a host with `:relay_enabled` unset
- WHEN any deploy runs
- THEN no `mjolnir-relay` unit is installed
- AND nothing is bound to UDP 443

### Requirement: The relay serves a certificate valid for its name
The relay SHALL serve WebTransport on UDP 443 with a certificate valid for `:relay_host`. It SHALL NOT start with a self-signed, expired or mismatched certificate.

#### Scenario: A browser connects by name
- GIVEN the relay running with an issued certificate for `relay.example.net`
- WHEN a browser opens a WebTransport session to `https://relay.example.net/`
- THEN the TLS handshake completes with no certificate hash supplied by the page

#### Scenario: No certificate
- GIVEN no certificate pair for `:relay_host`
- WHEN the unit starts
- THEN it exits non-zero and names the file it could not use

### Requirement: Every session needs a valid token
The relay SHALL refuse a browser session or an Iroh session that presents no token, a token it cannot verify, an expired token, or a token whose grant does not cover the requested path. It SHALL grant nothing to a session without a token.

#### Scenario: No token
- GIVEN a broadcast published at `t/<owner>/a/b`
- WHEN a browser opens a session to that path with no token
- THEN the session is refused
- AND it receives no announcement and no catalog

#### Scenario: Token for another tenant
- GIVEN a token that grants subscribe under `t/<owner1>/`
- WHEN its holder asks for a path under `t/<owner2>/`
- THEN the session is refused

#### Scenario: Valid token
- GIVEN a token that grants subscribe under `t/<owner>/a/`
- WHEN its holder subscribes to `t/<owner>/a/b`
- THEN media is delivered

### Requirement: A rotated key takes effect without a restart
The relay SHALL read its verification keys again when the key file changes. A token signed by a key that is no longer in the file SHALL be refused for new sessions.

#### Scenario: Key removed
- GIVEN a session admitted with a token signed by key K
- WHEN K is removed from the key file
- THEN a new session with a token signed by K is refused
- AND the relay process did not restart

### Requirement: Broadcasts live under a tenant prefix
The relay SHALL accept a publish only at a path that begins `t/<owner id>/`, where `<owner id>` is a canonical owner id and the token's grant names that same prefix.

#### Scenario: Publish outside the prefix
- GIVEN a token that grants publish under `t/<owner>/`
- WHEN its holder publishes at `live/x`
- THEN the publish is refused

### Requirement: The relay does not dial out for a client
The relay SHALL NOT open an Iroh connection because a session named a ticket or an endpoint.

#### Scenario: A session names a ticket
- GIVEN a valid token
- WHEN a session's path is a broadcast ticket
- THEN the session is refused
- AND the relay opened no outbound Iroh connection

### Requirement: Other deploys do not end calls
A gateway deploy, a controller deploy and a restart of `mjolnir-gateway` or `mjolnir` SHALL leave `mjolnir-relay` running and its sessions open. Stopping the relay SHALL drain sessions before exit.

#### Scenario: Gateway restart during a call
- GIVEN a browser playing a broadcast through the relay
- WHEN `mjolnir-gateway` restarts
- THEN playback continues
