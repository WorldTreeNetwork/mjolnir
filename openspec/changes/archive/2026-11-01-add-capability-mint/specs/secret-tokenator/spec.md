## ADDED Requirements

### Requirement: Deposit mints a holder-checked token

The host SHALL deposit a foreign secret through `Mjolnir.Secrets.Deposit.deposit/3`. The secret id SHALL be path-safe (no `/`, `\`, NUL, or `..`). The secret SHALL be a non-empty binary. The owner key SHALL be a 32-byte Ed25519 public key. The deposit SHALL store the secret only as `SecretStore.put_opaque("secrets", secret_id, "value", bytes)`.

It SHALL store opaque `meta` as UTF-8 JSON whose `salt_b64` is 32 CSPRNG bytes and whose `commitment_hex` is 64 lowercase hex characters of `Mjolnir.Biscuit.secret_commit(salt, secret)`. It SHALL store the owner fingerprint as opaque key `owner`, the lowercase hex of `Mjolnir.Biscuit.holder_fingerprint/1` on that public key. The fingerprint SHALL NOT be a Gordian envelope and SHALL NOT be required inside the JSON `meta`.

The deposit SHALL mint with `Mjolnir.Biscuit.mint_production(secret_id, "redeem")` and SHALL append a holder check for that fingerprint. The token SHALL NOT assert a holder fact, SHALL NOT contain the secret or the salt, and SHALL NOT carry a hop block. `mint/3` SHALL NOT be the production deposit path.

The deposit SHALL take the id by exclusive create of the `secrets/<id>` directory. If that create loses, or the directory already exists, the call SHALL return an error and SHALL NOT read, replace, or delete `value`, `meta`, `owner`, or any `.tmp` sibling already there. A separate existence check followed by writes SHALL NOT count as that reservation. There is no replace operation. An old token keeps naming the id it was minted for, and a later deposit SHALL NOT put a different secret under that id.

Success SHALL return the holder-checked token only after `value`, `meta`, and `owner` are published. A failure after this attempt won the directory SHALL delete only that directory, the objects this attempt wrote, and their `.tmp` siblings, and SHALL NOT return a token. If that cleanup itself fails, or the process dies, the leftover directory stays in place, no token is returned, and a later deposit SHALL NOT adopt or replace it. A refusal before the directory is created SHALL create nothing and SHALL preserve any directory that already exists. The host SHALL NOT log the secret bytes, and SHALL NOT include them in an error.

#### Scenario: Deposit stores the secret and the owner fingerprint

- GIVEN a path-safe secret id, a non-empty secret, and a 32-byte owner public key
- WHEN the host deposits
- THEN `value` is the secret
- AND `meta` commits that secret under the stored salt
- AND `owner` is the §5 fingerprint of that public key

#### Scenario: Authorization requires the injected holder

- GIVEN a token from that deposit
- WHEN the verifier injects the stored owner fingerprint
- THEN authorization of `redeem` on that secret id succeeds
- WHEN the verifier does not inject it
- THEN authorization fails

#### Scenario: Validation refusal writes nothing

- GIVEN an empty secret, a secret id that is not path-safe, or an owner key that is not 32 bytes
- WHEN deposit is attempted
- THEN it returns an error
- AND no directory is created for that id

#### Scenario: An existing id is preserved

- GIVEN a secret id whose directory already exists, including a partial one
- WHEN another deposit uses that id
- THEN it returns an error
- AND the existing objects are unchanged
- AND no token is returned

#### Scenario: One of two concurrent deposits wins

- GIVEN two deposits of the same new id
- WHEN both attempt the exclusive create
- THEN one succeeds
- AND the loser returns an error without replacing or deleting the winner's objects

#### Scenario: A failed publication returns no token

- GIVEN a reservation this attempt owns
- WHEN a later object write, the mint, or the holder append fails, and cleanup succeeds
- THEN no token is returned
- AND that attempt's directory is gone
- WHEN cleanup itself fails
- THEN no token is returned
- AND the leftover is not adopted by a later deposit
- AND the error does not contain the secret

#### Scenario: Token does not carry the secret

- GIVEN a deposited secret
- WHEN the minted token is decoded as text
- THEN the secret bytes are absent
