## ADDED Requirements

### Requirement: B0 self-hosted relay VM

A named Mjolnir app `buzz-relay` SHALL run the Buzz relay, Postgres,
Redis, and MinIO as systemd units inside **one** guest (Block
`deploy/compose/.env` is the env contract, not the runtime). That
guest's filesystem SHALL hold the community event log, object store,
and git volume. The advertised `RELAY_URL` SHALL be
`wss://buzz.identikey.me` from first boot (scheme, host, and empty
port, byte for byte). TLS SHALL terminate at the Mjolnir gateway;
the guest SHALL NOT run the Caddy overlay. The hive SHALL be treated
as stateful: a deploy cutover that boots a fresh rootfs SHALL NOT be
the upgrade path. `mj snapshot create` SHALL be the backup verb.

#### Scenario: Liveness on the vanity name

- GIVEN `buzz-relay` is running and `mj domain set buzz-relay buzz.identikey.me` has been applied
- WHEN a client requests `https://buzz.identikey.me/_liveness`
- THEN the response is HTTP 200

#### Scenario: Snapshot includes the hive

- GIVEN a self-hosted Buzz relay running as that VM
- WHEN the VM is snapshotted
- THEN the snapshot includes the event log (Postgres data directory)
- AND community events are not stored on the host Postgres sidecar

#### Scenario: RELAY_URL matches Join

- GIVEN the relay process
- WHEN Buzz Desktop joins with `wss://buzz.identikey.me`
- THEN NIP-11 / NIP-42 challenges advertise that exact URL
- AND NIP-98 does not 401 solely because of a host/port/scheme mismatch

### Requirement: Provider-deployed identity on our relay

A self-hosted Buzz relay used as the local-client target SHALL accept
the provider-deployed identity class (desktop-minted key plus NIP-OA
`auth_tag`). Closed membership SHALL stay on. The “plain member, no
auth_tag” workaround SHALL NOT be the default join path.

#### Scenario: Deployed agent is a relay member

- GIVEN our relay and a `deploy` that presents `private_key_nsec` and
  `auth_tag`
- WHEN the harness authenticates
- THEN the relay does not refuse with `restricted: not a relay member`
