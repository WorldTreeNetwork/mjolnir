## ADDED Requirements

### Requirement: Mint root is durable

The host SHALL mint production Biscuits with one Ed25519 root that survives process restart. The private key SHALL live in one file, mode `0600`, outside `btrfs_root`, default `/var/lib/mjolnir/biscuit-root`. The file body SHALL be 64 lowercase hex characters and an optional trailing newline. An operator SHALL provision that file. The host SHALL NOT create it, overwrite it, or repair its mode. A missing file, a malformed body, a mode other than `0600`, an unreadable file, or a path inside `btrfs_root` or the per-VM LUKS escrow directory SHALL fail closed and SHALL NOT generate a replacement root. The private key SHALL NOT be supplied by an environment variable, SHALL NOT appear in subprocess argv, and SHALL NOT appear in exception text or subprocess diagnostics.

`Mjolnir.Biscuit.authority/0` SHALL be the production load. It SHALL cache the key in the BEAM. `mint_production/2` SHALL use that cache. `mint/3` SHALL remain an explicit-key helper and SHALL NOT load the host root. Application start SHALL publish the public half as `biscuit_public_hex` before the HTTP server accepts redeem. When `MJOLNIR_BISCUIT_PUBLIC_HEX` is set and disagrees with the file, boot SHALL fail closed. When it is unset, the verifier SHALL be the public half of the file. The production CLI request SHALL travel on stdin.

#### Scenario: Two mints share a public key

- GIVEN a configured durable mint root
- WHEN the host mints two production Biscuits
- THEN both verify with the same public hex
- AND that hex is `biscuit_public_hex`

#### Scenario: Restart reloads the same file

- GIVEN a token minted from the durable root
- WHEN a new process discards the cached key and loads the same file
- THEN the token verifies with the reloaded public key
- AND a new production mint uses that same public key

#### Scenario: Missing root fails closed

- GIVEN no durable mint root
- WHEN production mint runs
- THEN it returns an error
- AND it does not persist a newly generated root

#### Scenario: Bad file fails closed

- GIVEN a root file that is malformed, unreadable, or not mode `0600`
- WHEN the host loads the authority
- THEN load fails closed
- AND the file is left unchanged

#### Scenario: Configured public hex must match

- GIVEN a root file and a `MJOLNIR_BISCUIT_PUBLIC_HEX` that is not its public half
- WHEN the host boots
- THEN boot fails closed

#### Scenario: Unset public override derives the verifier

- GIVEN a valid root file and no `MJOLNIR_BISCUIT_PUBLIC_HEX`
- WHEN the host boots
- THEN `biscuit_public_hex` is the public half of that file

#### Scenario: Private key stays off argv

- GIVEN a production mint
- WHEN the host invokes `mjolnir-biscuit`
- THEN the private key is on stdin and not in argv
- AND a failing invocation does not include the private key in the error
