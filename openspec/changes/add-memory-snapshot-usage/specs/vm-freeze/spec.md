## ADDED Requirements

### Requirement: Storage reports memory snapshots apart from CoW snapshots
`GET /api/storage` and `mj storage` SHALL report memory-snapshot usage as its own count, logical bytes, and exclusive bytes. That report SHALL NOT be only the `@snapshots` area total. A host with no memory snapshots SHALL report a count of zero. The system SHALL NOT add a second compression pass; on-disk size follows the btrfs mount compression.

#### Scenario: Frozen RAM is visible beside the snapshot area
- GIVEN one filesystem snapshot and one memory snapshot
- WHEN the operator runs `mj storage`
- THEN memory-snapshot count is 1
- AND the memory-snapshot byte count is separate from the `@snapshots` area

#### Scenario: No freezes
- GIVEN no `@snapshots/*.mem` directory
- WHEN `GET /api/storage` is called
- THEN the memory-snapshot count is 0
