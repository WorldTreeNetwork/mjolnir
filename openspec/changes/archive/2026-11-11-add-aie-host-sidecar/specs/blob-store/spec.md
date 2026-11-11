## MODIFIED Requirements

### Requirement: Guests are told the door URL, never B2 keys
<!-- base: 2787fd0d525442d03f6e0152d99ec4ae39dc73b2 openspec/specs/blob-store/spec.md -->

On every boot the host SHALL inject locators as a map via vsock
`configure_identity`. The guest SHALL persist that map in
`/etc/mjolnir/vm.json`. The map SHALL include `api_url` and
`blob_door_url` (the overlay HTTP origin, e.g.
`http://10.200.0.1:7222`). When the AIE sidecar is up and
`/dev/accel/accel0` exists, the map SHALL also include `aie_url`
(e.g. `http://10.200.0.1:7422`). When the sidecar is stopped or
the device is missing, the host SHALL omit `aie_url` and SHALL
NOT remove `api_url` or `blob_door_url`. The guest SHALL NOT
receive `B2_*` credentials or the door's environment file.

#### Scenario: Fresh spawn

- GIVEN a VM has booted
- WHEN `/etc/mjolnir/vm.json` is read
- THEN it contains `blob_door_url` equal to `http://10.200.0.1:7222`
- AND locators are a map
- AND it does not contain a B2 application key

#### Scenario: AIE locator when the sidecar is up

- GIVEN `/dev/accel/accel0` and a running AIE sidecar
- WHEN a guest boots
- THEN `aie_url` is present in the locator map
- AND `blob_door_url` is still present

#### Scenario: AIE locator omitted when off

- GIVEN no `/dev/accel/accel0` or a stopped AIE sidecar
- WHEN a guest boots
- THEN `aie_url` is absent
- AND `blob_door_url` is unchanged

#### Scenario: B2 keys appear in the guest

- GIVEN a change that copies `blob-door.env` or `B2_*` into a VM
- WHEN it is reviewed
- THEN it is rejected against this requirement
