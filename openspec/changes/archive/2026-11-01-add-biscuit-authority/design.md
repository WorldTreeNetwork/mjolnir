# Design

## Durable root

The folded runtime can mint and verify. It cannot remember a root. `Biscuit.keypair/0` runs the CLI `keypair` op, which calls `new_keypair()`. `biscuit_public_hex` is whatever `MJOLNIR_BISCUIT_PUBLIC_HEX` was at boot. Nothing checks that those two keys are a pair.

Production mint loads one Ed25519 private key, and the public half of that key is the verifier. A second mint in the same boot uses the same key. A restart uses the same key. Tests that need a throwaway pair keep calling the ephemeral generator. That generator is not the host root.

If the private key is missing, or its public half disagrees with the configured hex, mint returns an error and does not invent a replacement root.

## Key home

[AUTO] "activate and run" implies `--go`. The open steer fork is logged lean: one file, mode `0600`, outside `btrfs_root`. Default path `/var/lib/mjolnir/biscuit-root`. It is not a file under `/var/lib/mjolnir/escrow` and not an environment variable holding the private bytes.

The file body is the private key as 64 lowercase hex characters and an optional trailing newline. An operator provisions it before boot. The host does not create it, does not overwrite it, and does not chmod it into existence. Missing, malformed, unreadable, mode other than `0600`, or a path inside `btrfs_root` or the escrow directory fails closed.

## Load and transport

`Mjolnir.Biscuit.authority/0` is the production entry. It reads the file once per boot and caches the key in the BEAM. `mint_production/2` uses that cache. `mint/3` stays the explicit-key path for tests and does not load the host root.

The public half is written into `biscuit_public_hex` during application start, before the HTTP server accepts redeem. `MJOLNIR_BISCUIT_PUBLIC_HEX`, when set, must equal that public half or boot fails closed. When it is unset, the verifier is the public half of the file.

The CLI already reads the JSON request on stdin (`mjolnir-biscuit.rs` around the stdin read). Production calls pass that JSON on stdin. They do not put `private_hex` in argv. A failed CLI call raises without the private hex and without the raw subprocess body.

## Unverified hypotheses

None. The fence-channel spike belongs to `add-guest-fence-host`, not this root.
