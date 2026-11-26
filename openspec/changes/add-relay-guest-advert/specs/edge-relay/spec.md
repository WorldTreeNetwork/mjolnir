## ADDED Requirements

### Requirement: Guest identity advertises the local relay's public locators

The relay SHALL publish the loaded public hostname and the bound Iroh endpoint's public ID as an atomic runtime document at `/run/mjolnir-relay/locator.json`, scoped to that unit invocation. It SHALL withdraw the document at drain and leave no document from a stopped or failed invocation once the unit has cleaned up. At guest identity setup on boot or disk resume, the host SHALL read `/etc/mjolnir-relay/relay.env` and the runtime document afresh. If the relay is enabled and the document supplies a valid endpoint ID for the configured hostname, the host SHALL write two top-level strings in `/etc/mjolnir/vm.json`. It SHALL set `relay_url` to `https://<host>/` and `relay_iroh_endpoint_id` to the full lowercase hex public ID. If the relay is disabled or the required inputs are missing, unreadable, malformed, or disagree, both fields SHALL be absent after identity setup, including when older fields existed. The locator write SHALL contain no token, private key or other credential. A continuously running guest keeps the values from its last identity setup until boot or disk resume. Thawing a memory snapshot restores the captured `vm.json`.

#### Scenario: Enabled host with a published endpoint

- GIVEN an enabled relay with a valid current runtime document
- WHEN a guest boots and identity setup succeeds
- THEN the guest identity file contains the WebTransport URL and that relay process's public Iroh endpoint ID
- AND neither locator carries credentials

#### Scenario: Resume after disable or loss of readable config

- GIVEN a guest identity file with relay locators from an earlier setup
- WHEN the guest resumes and identity setup succeeds with the relay disabled, the config unreadable, or the runtime locator unavailable or invalid
- THEN the guest identity file omits both relay fields and still contains the other applicable identity fields

#### Scenario: Resume after a relay identity change

- GIVEN an enabled relay that restarted and published a different endpoint ID for the configured hostname
- WHEN the guest resumes and identity setup succeeds
- THEN the guest locators correspond to the current runtime document

#### Scenario: Guest starts during relay drain

- GIVEN a relay that published its runtime document and has begun draining
- WHEN a guest boots and identity setup succeeds
- THEN the guest identity file omits both relay fields

#### Scenario: Catalog discovery

- GIVEN an operator or guest developer reading the host-sidecars catalog
- WHEN they look up the edge relay
- THEN they find its public listener, both guest locator fields, availability and refresh rules, and the room-token command
