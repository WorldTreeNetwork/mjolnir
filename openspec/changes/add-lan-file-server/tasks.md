# Tasks

Implementation of living `lan-files` for `mjolnir-h2fp.3`.
No requirement delta: the folded spec is unchanged.

- [ ] Small guest links `identikey-auth` and `recrypt-storage-auth` and does not modify `recrypt-server`
- [ ] Challenge `aud` is one fixed service id, not derived from Host, address, or port
- [ ] GET checks a storage-auth Capability: `Blake3(raw key)`, `read`, root issuer equals recorded `ownership(h)`
- [ ] First put records ownership; caps and that index persist on the guest subvolume
- [ ] Guest put/get uses the TAP-only blob-door URL; the door does not bind `0.0.0.0:7222`
- [ ] Host DNAT publishes guest HTTP on the Ethernet interface that holds the LAN address, and waits or fails when that address is absent
- [ ] From another host on `192.168.0.0/24`, an authorized GET succeeds

## Owed from architecture advise (2026-10-26)

See `reviews/2026-10-26-advise.md` for rationale and source evidence. These boxes require design/acceptance clarification before a fresh advise; the implementation boxes above remain open.

- [ ] R1: Pin the authenticated PUT/GET wire flow, proof/session lifetime and nonce handling, owner-compatible cap signing/import, durable issuer-key lookup/recovery, and parent-cap policy. Specify signature/expiry, File kind, exact hash, mapped holder, read, and key-bound root-owner checks; include negative auth/cap cases and authorized GET after restart without owner re-login.
- [ ] R2: Specify body/hash validation, door acknowledgement, ownership/cap/key persistence ordering and the PUT success boundary; define recovery for concurrent putters, retries, lost door responses, crashes and metadata failures without DELETE rollback, ownership replacement, or presence-only ownership claims. Add failure/race/restart acceptance checks.
- [ ] R3: Pin DNAT ingress interface plus current LAN destination IP/port and guest target, the owner of idempotent rule setup/reconciliation/removal, and FORWARD/return-path handling. Define address-loss/change and guest-stop/replacement behavior; add rule inspection and negative ingress/destination/absent-address checks alongside the external LAN success proof.

Out of scope:

- Mesh ULA proxy and `meshd publish` (`mjolnir-h2fp.4`)
- `add-iroh-blobs`
- BEAM linkage of the Recrypt crates

## Worker handoff (2026-10-26)

Implementation is staged in `native/mjolnir_lan_files`, `Mjolnir.LanFiles`,
`Mjolnir.Network`, and the VM lifecycle hooks. The guest README documents
wire encoding, guest startup, host publication configuration, and the two
source revisions verified/embedded by its build script. The ownership public
key and ownership claim are one FULL-synchronous SQLite transaction.

Focused targets were created with auth/cap negatives, restart, first-owner
race, orphan/metadata failure, door ordering, and pure DNAT inspection and
lifecycle checks. Neither target could reach compilation in this sandbox:

- `mix test test/mjolnir/lan_files_publish_test.exs`: Mix TCP filesystem lock
  denied with `:eperm`, including one retry.
- `cargo test --manifest-path native/mjolnir_lan_files/Cargo.toml`: crates.io
  DNS resolution failed, including one retry.

All owed boxes remain open pending executable verification. No live rules,
service restart, guest deployment, or second-host LAN GET was attempted.
The conductor must persist the edits and rerun the two packet commands in
an environment with the required lock/network access and clean pinned sibling
source checkouts. Cargo will also need to update the workspace lockfile,
which is outside this worker's declared paths.
