## ADDED Requirements

### Requirement: Taskmaster talks to the door

Taskmaster SHALL put and get blobs only via the blob door HTTP
surface. It SHALL persist the content hash (and optional size /
content-type) in its work-graph database. It SHALL NOT persist blob
bytes and SHALL NOT hold B2 credentials.

#### Scenario: Attachment is stored

- GIVEN `BLOB_DOOR_URL` points at a door
- WHEN Taskmaster accepts a body
- THEN it PUTs to `/storage/blob/b3/{hash}` on that door
- AND it writes a row keyed by that hash
- AND the row does not contain the body

#### Scenario: Door URL is missing

- GIVEN `BLOB_DOOR_URL` is unset
- WHEN a put or get is attempted
- THEN it fails closed
- AND no B2 environment variable is read
