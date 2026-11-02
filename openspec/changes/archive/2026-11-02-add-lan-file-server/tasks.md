# Tasks

Implementation of living `lan-files` for `mjolnir-h2fp.3`.
No requirement delta: the folded spec is unchanged.

- [x] Small guest links `identikey-auth` and `recrypt-storage-auth` and does not modify `recrypt-server`
- [x] Challenge `aud` is one fixed service id, not derived from Host, address, or port (`mjolnir:lan-files:v1`)
- [x] GET checks a storage-auth Capability: `Blake3(raw key)`, `read`, root issuer equals recorded `ownership(h)`
- [x] First put records ownership; caps and that index persist on the guest subvolume
- [x] Guest put/get uses the TAP-only blob-door URL; the door does not bind `0.0.0.0:7222`
- [x] Host DNAT publishes guest HTTP on the Ethernet interface that holds the LAN address, and waits or fails when that address is absent
- [ ] From another host on `192.168.0.0/24`, an authorized GET succeeds. The host was no longer on that prefix. The second-host proof that closed `mjolnir-h2fp.3` (2026-10-30) was a Mac at `10.43.1.120` on Symbio: challenge 200 (70 bytes), unauthenticated GET 401, authorized GET `ok` for hash `B8teHohm2jYAvMdHt6gy8PGAhfqbJsPhEt2Wekm7pwYb` (15 bytes). Packets entered `wlp191s0`.

## Owed from architecture advise (2026-10-26)

See `reviews/2026-10-26-advise.md` for rationale and source evidence. These boxes require design/acceptance clarification before a fresh advise; the implementation boxes above remain open.

- [x] R1: Pin the authenticated PUT/GET wire flow, proof/session lifetime and nonce handling, owner-compatible cap signing/import, durable issuer-key lookup/recovery, and parent-cap policy. Specify signature/expiry, File kind, exact hash, mapped holder, read, and key-bound root-owner checks; include negative auth/cap cases and authorized GET after restart without owner re-login. Pinned in `design.md`. Unit coverage is `get_predicate_and_durable_owner_key_after_restart` and `auth_wrong_audience_replay_and_tampered_signature`. A live guest-restart GET was not run.
- [x] R2: Specify body/hash validation, door acknowledgement, ownership/cap/key persistence ordering and the PUT success boundary; define recovery for concurrent putters, retries, lost door responses, crashes and metadata failures without DELETE rollback, ownership replacement, or presence-only ownership claims. Add failure/race/restart acceptance checks. Pinned in `design.md`. Unit coverage is `put_requires_door_success_and_hash_before_ownership`, `orphan_is_not_an_owner_and_metadata_failure_is_failed_put`, and `concurrent_different_owners_cannot_replace_winner`.
- [x] R3: Pin DNAT ingress interface plus current LAN destination IP/port and guest target, the owner of idempotent rule setup/reconciliation/removal, and FORWARD/return-path handling. Define address-loss/change and guest-stop/replacement behavior; add rule inspection and negative ingress/destination/absent-address checks alongside the external LAN success proof. Pinned in `design.md`. `test/mjolnir/lan_files_publish_test.exs` covers the rule shape, replacement, stop, and address loss. Live rule removal on guest stop was not inspected.

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

## Fold note (2026-11-02)

The share later ran on this host. Guest `13daU4EVEt41Z3CDxLEgkA`,
DNAT on the address then held by `wlp191s0`, memory blob-door on
`10.200.0.1:7222` only. `mjolnir-h2fp.4` closed on
`lan-files.wxow.mesh` resolved from `tr3000` to that DHCP address.
No IPv6 proxy was added. `cargo test -p mjolnir-lan-files` on this
fold did not rebuild: `identikey-protocol` HEAD was
`be1f9a9b8ef988c37d64e6a121e8648537ae6931`, and `build.rs` still
pins `8cd455c7308e86c50a0b338b82c7d8e814b4b96e`. `mix test` of
`lan_files_publish_test.exs` and `lan_files_install_test.exs`
finished after the archive was cut: 9 passed. The `192.168.0.0/24`
box stays open. Mesh ULA routing stays a Lightning Mesh question.
