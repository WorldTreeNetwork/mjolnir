## ADDED Requirements

### Requirement: Fence identity comes from the host channel

The host SHALL supply journal identity, the owner-instance handle, and a monotonic generation on an authenticated channel. The guest disk SHALL NOT be the source of those three values.

`identity` SHALL return the host journal and the host instance. The monotonic generation SHALL travel on the grant, which the host also owns. The guest disk SHALL NOT supply any of the three.

#### Scenario: Copied disk is not ownership

- GIVEN a guest whose disk contains a journal id, an instance handle, and a generation
- WHEN the host answers `identity` on the authenticated channel
- THEN the answer is the host journal and the host instance
- AND the generation on the resulting grant is the host generation
- AND neither value is taken from the copied disk

### Requirement: Classification covers retained admissions

`classify` SHALL compare the guest receipts to every admission the host retains, including keys the guest does not list. An uncertain row, a missing key, or a digest mismatch SHALL produce an incomplete classification. Adoption SHALL stop while classification is incomplete.

#### Scenario: Uncertain row stops adoption

- GIVEN the host retains an admission the guest receipts do not cover
- WHEN the guest begins adoption
- THEN classification is incomplete
- AND no new owner is elected

### Requirement: Adoption is idempotent

`begin_adoption` SHALL return the grant the host already holds for that designated instance and history, whether the grant is pending or confirmed. It SHALL NOT issue a second grant, SHALL NOT demote a confirmed grant to pending, and SHALL NOT advance the generation. A retry by the same designated instance, including one that classifies again and gets a fresh valid classification of the same history, SHALL return that same grant. `confirm` SHALL be idempotent for that instance and that grant, and SHALL move a pending grant to confirmed. A lost begin reply, a failure before confirm, or a lost confirm reply SHALL recover that same grant in the state the host already recorded. Recovery SHALL be `classify`, then `begin_adoption`, then `commit(Adopt)`, then `confirm`. `commit(Adopt)` SHALL validate and persist adoption of the supplied grant. It SHALL NOT issue another grant and SHALL NOT demote a confirmed grant. A pending grant SHALL NOT permit Lease or Admit. Another instance SHALL NOT confirm the grant. A copied grant SHALL NOT elect a different instance as owner. An authenticated instance that the host has not designated SHALL NOT elect itself by calling `begin_adoption`.

#### Scenario: Lost begin reply returns the same pending grant

- GIVEN a pending grant whose begin reply was lost
- WHEN the same designated instance begins adoption again with a fresh valid classification of the same history
- THEN the host returns that same pending grant
- AND the generation does not advance

#### Scenario: Failure before confirm returns the same pending grant

- GIVEN a pending grant and a failure after begin and before confirm
- WHEN the same designated instance runs classify, begin_adoption, commit(Adopt), and confirm
- THEN begin_adoption returns that same pending grant
- AND commit(Adopt) persists that grant and does not issue another
- AND confirm moves it to confirmed
- AND the generation does not advance

#### Scenario: Lost confirm reply stays confirmed through the full retry

- GIVEN a grant the host has already confirmed and a lost confirm reply
- WHEN the same designated instance runs classify, begin_adoption, commit(Adopt), and confirm
- THEN begin_adoption returns that same confirmed grant
- AND commit(Adopt) does not demote it and does not issue another grant
- AND confirm leaves it confirmed
- AND the generation does not advance

#### Scenario: Pending grant cannot lease or admit

- GIVEN a pending grant
- WHEN the instance attempts Lease or Admit
- THEN the host rejects the mutation

#### Scenario: Another instance cannot confirm

- GIVEN a pending grant for instance A
- WHEN instance B calls confirm with that grant
- THEN instance B is not the owner

#### Scenario: Copied grant does not elect

- GIVEN a grant issued to instance A
- WHEN instance B presents that grant
- THEN instance B is not the owner

#### Scenario: Undesignated instance cannot elect itself

- GIVEN an authenticated instance the host has not designated, and receipts that classify completely
- WHEN that instance calls begin_adoption
- THEN the host does not issue a grant
- AND that instance is not the owner

### Requirement: Commit is the acceptance boundary

`commit` SHALL make the admission and its ownership and generation binding durable before it invokes or releases the guest write, including when `commit` never returns. Transfer and revocation SHALL share that serialization boundary. A lost guest write SHALL leave the durable admission in place. Lost contact or revocation SHALL drop the lease before the next mutation. An already admitted row SHALL stay recorded and SHALL NOT be resent. `begin_adoption`, `confirm`, and transfer SHALL make their ownership transitions durable before the host exposes the result. A crash after begin and before commit SHALL NOT reuse that generation and SHALL NOT forget the pending grant.

#### Scenario: Acceptance is durable before the guest write

- GIVEN a current grant and a mutation the host accepts
- WHEN `commit` runs and the host crashes before it returns, after it would have invoked the guest write
- THEN the admission and its ownership and generation binding are already durable
- AND a failed or never-started guest write does not erase that record

#### Scenario: Crash after begin keeps the pending grant

- GIVEN a begin_adoption that has exposed its result
- WHEN the host crashes before commit
- THEN the pending grant and its generation are still present
- AND a retry does not issue a second grant or reuse a new generation

### Requirement: Transfer and restore drop the old grant

A transfer SHALL revoke the previous grant and issue a new instance handle. A restored or cloned guest SHALL receive a new generation and SHALL NOT keep the previous grants.

#### Scenario: Clone does not keep the old grants

- GIVEN a guest restored or cloned from an image that held grants
- WHEN the host identifies that guest
- THEN the generation is new
- AND the previous grants do not authorize it

### Requirement: Receipts are observations

A receipt SHALL carry scope, key, digest, claim state, and generation. It SHALL NOT carry secret bytes or a response body. A receipt SHALL NOT be treated as exactly-once proof of an upstream effect. Admitting an effect SHALL NOT permit a send.

#### Scenario: Receipt has no secret

- GIVEN an admitted row
- WHEN the host returns its receipt
- THEN the receipt has no secret bytes and no response body

### Requirement: Classification is bound to current history

A classification SHALL be bound to one journal, one instance, and the history it covered. The host identifies a classification by the id it issued. Another holder of that same id, under the same instance, is the same classification. The host SHALL NOT treat a byte-identical copy of that id as a different classification. The accepting owner's coverage SHALL advance atomically on that issued id with each mutation that owner accepts, so that id covers the history after those accepted mutations. A separately issued classification, whose coverage the host did not advance, SHALL become stale once a later admission exists that it does not cover. Other instances' classifications SHALL stay stale across that advancement. Coverage of a classification other than the accepting owner's advanced id SHALL be checked again at begin, commit, and transfer. An unknown guest row during classification, a receipt whose generation disagrees with the retained admission for that key, or a foreign classification SHALL be rejected. A receipt generation SHALL be compared with the generation stored on that retained admission, not with the current ownership grant. Generation zero SHALL mean a legacy unfenced row and SHALL NOT be host admission authority. Adoption and commit SHALL NOT proceed on a stale or foreign classification.

#### Scenario: Two successive claims by the active owner succeed

- GIVEN a designated owner whose adoption produced a complete classification
- WHEN that owner admits one new key and then admits a second distinct key using the same classification
- THEN both admissions succeed
- AND the owner's coverage includes both keys after the second admission
- AND the generation on the grant does not change

#### Scenario: A separately issued classification stays stale

- GIVEN one instance obtains two complete classifications, C0 and C1, of the same history
- AND that instance adopts with C1 and accepts a new key using C1
- WHEN begin or commit uses C0
- THEN the host rejects C0 as stale
- AND it does not create an admission from C0
- WHEN that same instance admits another distinct key using C1
- THEN the admission succeeds
- AND C1's coverage includes both new keys

#### Scenario: Later admission makes an empty classification stale

- GIVEN a complete classification of an empty history that is not the accepting owner's advanced coverage
- WHEN the host retains a new admission before begin or commit uses that classification
- THEN the classification is stale
- AND begin or commit rejects it

#### Scenario: Unknown row is rejected

- GIVEN a guest receipt for a key the host does not retain
- WHEN the host classifies
- THEN classification is rejected

#### Scenario: Foreign classification is rejected

- GIVEN a complete classification bound to instance A
- WHEN instance B presents that classification at begin or commit
- THEN the host rejects it
- AND instance B is not elected

#### Scenario: Historical receipt generations stay valid

- GIVEN an admission recorded at generation 1 and a later ownership grant at generation 2
- WHEN the guest presents the generation-1 receipt and classify compares it to that retained admission
- THEN the receipt is valid historical evidence
- AND the current grant remains generation 2

#### Scenario: Receipt that disagrees with its admission is rejected

- GIVEN a retained admission whose generation is 1
- WHEN the guest presents a receipt for that key whose generation is not 1
- THEN classification is rejected
- AND no new admission is created
- AND the check does not use the current ownership grant as that receipt's expected generation

#### Scenario: Generation zero is not host authority

- GIVEN a receipt whose generation is zero
- WHEN the host classifies
- THEN that row is legacy evidence
- AND it does not authorize a host admission

### Requirement: Mutations have separate authority

Adopt SHALL require a host-designated instance and a complete current classification. `begin_adoption` SHALL be what issues the grant. `commit(Adopt)` SHALL validate and persist adoption of the supplied grant and SHALL NOT issue another one. A pending grant SHALL stay pending. A confirmed grant SHALL stay confirmed. Lease and Admit SHALL require a confirmed grant for that instance, the matching journal and generation, and the exact mutation. A valid fresh Admit SHALL introduce a key the host does not yet retain. Reconcile SHALL be a separate authorization. It MAY name a revoked grant to identify existing work, and it SHALL NOT create an admission. A revoked grant alone SHALL NOT authorize the reconciler. An unknown key during Reconcile, or an unknown receipt during classification, SHALL fail closed and SHALL NOT admit. A same-key digest conflict on Admit, or a receipt whose digest disagrees with the retained admission at classify, SHALL fail closed and SHALL NOT admit or permit a send. Reconcile SHALL carry scope and key only. It SHALL check separate authorization and the existing key, and it SHALL leave the retained digest unchanged. An unrecognized effect-contract identifier SHALL fail closed and SHALL NOT admit or permit a send.

#### Scenario: Fresh Admit introduces a key

- GIVEN a confirmed grant for the designated instance, a matching journal and generation, and a key the host does not retain
- WHEN Admit submits that exact mutation and a policy-owned effect contract
- THEN the host admits the key
- AND the admission does not permit a send

#### Scenario: Unknown key on Reconcile is rejected

- GIVEN a separately authorized reconcile and a key the host does not retain
- WHEN Reconcile names that key, even with a revoked grant bound to the same journal, instance, and generation
- THEN the host rejects it
- AND no admission is created

#### Scenario: Same-key digest conflict on Admit is rejected

- GIVEN an admitted key and an Admit for that key with a different digest
- WHEN Admit submits it under an otherwise exact grant binding
- THEN the host rejects it
- AND the stored digest does not change

#### Scenario: Classify rejects a receipt digest that disagrees

- GIVEN a retained admission for a key
- WHEN the guest receipt for that key carries a different digest
- THEN classification is rejected
- AND the stored digest does not change

#### Scenario: Reconcile does not carry a digest

- GIVEN a separately authorized reconcile and an existing admitted key
- WHEN Reconcile names that scope and key
- THEN the host checks authorization and the existing key
- AND the retained digest is unchanged
- AND the payload has no digest and no terminal outcome

#### Scenario: Revoked grant may identify a reconcile and cannot admit

- GIVEN a revoked grant and an existing admitted key
- WHEN a separately authorized reconcile names that grant and that key
- THEN the host identifies the existing admission
- AND it does not create a new admission

#### Scenario: Unauthorized reconcile fails

- GIVEN a caller who is not authorized to reconcile
- WHEN they submit Reconcile
- THEN the host rejects it
- AND no admission is created

#### Scenario: Unrecognized effect contract fails

- GIVEN a confirmed grant and an effect-contract identifier the policy does not own
- WHEN Admit runs
- THEN the host rejects it
- AND no send is permitted

### Requirement: Acceptance survives restart

The host SHALL durably retain accepted admissions, the current generation, and ownership grants before it invokes or releases the guest write, and before it exposes the result of begin, confirm, or transfer. A host restart SHALL reload them. A lost acceptance reply SHALL leave the record in place, and a retry SHALL NOT send the effect again. Uncertain or unavailable recovery SHALL fail closed, SHALL NOT reset the generation, and SHALL NOT drop an unresolved admission. Commit SHALL NOT be a reusable authorization token. A transfer or revocation that arrives while a guest write is stalled, or while the channel is disconnected, SHALL still share that boundary: the old grant stops authorizing, and an acceptance already made durable is not sent again.

#### Scenario: Restart keeps an accepted key

- GIVEN a commit that recorded acceptance and then the host process restarts
- WHEN the host loads again
- THEN the accepted key and the generation are still present

#### Scenario: Lost accept reply is not resent

- GIVEN an acceptance the guest did not see
- WHEN the guest retries that mutation
- THEN the host returns the existing record
- AND it does not send the effect again

#### Scenario: Transfer during a stalled guest write revokes the old grant

- GIVEN a commit whose admission is already durable and whose guest write has not finished
- WHEN transfer or revocation runs before that write returns, or the channel disconnects
- THEN the old grant no longer authorizes a mutation
- AND the durable admission is not sent again
- AND the acceptance response is not a reusable token
