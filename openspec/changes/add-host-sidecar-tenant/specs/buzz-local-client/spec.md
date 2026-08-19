## MODIFIED Requirements

### Requirement: Host sidecar is control-plane by default

The OTP-managed Postgres sidecar SHALL store derived host-service
indexes as schemas in the existing host database `mjolnir`. It SHALL
NOT hold a Buzz community event log. A declared tenant database
(capability `host-postgres`) MAY live in the same Postgres process as
a separate `CREATE DATABASE`. Guests SHALL have no path to the
sidecar unless their spawn is given that tenant’s connect secret.
Default guests SHALL NOT reach the Unix socket or the tenant TCP
listener.

#### Scenario: Unprovisioned guest cannot reach the sidecar

- GIVEN a running guest with no tenant-database secret
- WHEN the guest attempts TCP, vsock, or a Unix-socket connect to host Postgres
- THEN the connection is not possible by default configuration

#### Scenario: Buzz events stay off the sidecar

- GIVEN the host sidecar
- WHEN Buzz community events are stored
- THEN they are not written to the sidecar
