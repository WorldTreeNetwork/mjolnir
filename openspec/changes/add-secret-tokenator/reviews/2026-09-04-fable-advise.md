# Advise — add-secret-tokenator (architecture)

> **ADVISE:** send-back
> **READER:** fable-5.1-arch-review
> **SPAWN:** .spawns/advise-add-secret-tokenator-fable-1788535586-453940-f46e4e91

Reader: fable-5.1-arch-review (other-family; author family is Grok;
ADR-005). Rigor: architecture. Scope: ADR 0008 + deltas, not the
unwritten HTTP/NIF/CLI. Third other-family read this date; opus-4.8
and sol both accepted. This read disagrees on two points that are
verifiable against code that already ships, not on the shape.

## Blind pass (Why + living spec + ADR 0008 + `put_opaque/4`, before design.md)

1. Pin: commitment is domain-separated salted Blake3; fixed-length
   domain and salt make plain concatenation unambiguous. Fine.
2. Pin: real Blake3 has no source in-tree (`mix.exs:78-81` records
   the NIF attempt failing). Which crate/NIF is the runtime node's
   call, but the dependency edge must be hard.
3. Pin: "token identity" in the signed tuple needs one canonical
   encoding before two implementations exist.
4. Pin: nonce store is in-BEAM state; restart loses it, which is
   fail-closed (unknown nonce rejects). Bound it or it is a memory
   surface for anyone on the overlay.
5. Pin: the redeem response must go over the guest's own TCP to
   `api_url`, never via `mj exec` stdout, which is logged.
6. Pin: `put_opaque` is host-global, not keyed by owner fp; the
   mint node must check `meta.owner_fp` on deposit/mint/list.
7. Refuse: any unsalted digest, SHA-256 stub as Blake3, redeem on
   `@skip_auth_paths`, a second overlay port.
8. Concern: where does `<secret_store_root>/_opaque/` sit relative
   to things that copy trees off the box or into snapshots? The
   design rejects env-in-rootfs because snapshots clone it; the
   same test must be applied to the vault's own path.
9. Concern: "stay in process memory or tmpfs" assumes RAM is never
   persisted. This repo has a freeze verb. Is RAM a snapshot sink?
10. Tradeoff: copy-out is the right v1 primitive; the cost is that
    the host loses control post-redeem, so every host-side sink of
    guest state must be enumerated, not just the rootfs.

## Compare

Items 1–7 converge with the design and with the opus/sol reads:
Decision 1 pins real Blake3 and routes it to `add-biscuit-runtime`;
Decision 3 signs `{biscuit_hash, nonce, aud}` (stronger than my take,
audience too); the fourth Auth branch and the four rejection
scenarios are in the delta. Sol's N4 covers item 6. No dispute.

Items 8–10 are where the design has not answered, and code answers
against it.

## Findings (send-back)

### 1. The vault path is inside the tree the nightly B2 backup copies off-box, append-only

`secret_store_root` is `/var/lib/mjolnir/btrfs/@sites/keyspace`
(`config/config.exs:124`). `put_opaque` writes
`<secret_store_root>/_opaque/<kind>/<id>/<key>`
(`secret_store.ex:498-499`). `scripts/backup-sites-b2.sh` runs
`rclone copy /var/lib/mjolnir/btrfs/@sites` to
`b2:mimir-backups/mjolnir-sites/<hostname>` daily via
`mjolnir-sites-backup.timer`, excluding only `plaintext-cache/**`
(`backup-sites-b2.sh:30, 50-52`). The remote is `hard_delete=false`
and `copy` never deletes on the destination (script header, lines
8-14).

So a deposited PAT is copied to Backblaze in plaintext the next
night, and `delete_opaque` on the host never removes it there.
Decision 1 rejected "env files in the rootfs" because "cloned by
every snapshot"; the chosen location is cloned by every backup, to
a third party, with no purge path. That is a worse version of the
rejected option. The repo already has the precedent for the fix:
`secret_escrow_dir` is deliberately placed outside `btrfs_root`
"so it is never captured by a VM snapshot" (`config.exs:34-38`).

This is architecture, not implementer detail: it decides whether
the vault is `put_opaque` under `secret_store_root` at all, or a
`secrets` kind with its own root. Either amend is one paragraph.

Owed: Decision 1 names the vault's on-disk root relative to
`backup-sites-b2.sh` and picks one of (a) a root outside `@sites`
(escrow precedent), or (b) `--exclude 'keyspace/_opaque/**'` in
the backup and a note that the exclusion is load-bearing. Add a
spec SHALL: secret bytes SHALL NOT be copied off-host by Mjolnir's
own backup jobs; durability of a foreign secret is the owner's.
Add the rejection scenario.

Note for the conductor, not owed here: the Buzz nsec at
`_opaque/vms/<id>/` has the same exposure today. Worth a bead.

### 2. `mj freeze` persists guest RAM; "process memory or tmpfs" is a snapshot sink now

`openspec/specs/vm-freeze/spec.md` (folded this date, `11c6bfe`):
`mj freeze` captures "filesystem + guest RAM" into
`@snapshots/<name>.mem` (`memory_snapshot.ex:100-101`), catalogued
by `GET /api/snapshots`, thawable into the same id, and remappable
under `.mem.forks/<new_vm_id>` (`memory_snapshot.ex:441-442`).
tmpfs is guest RAM, so both halves of the spec's mitigation
("SHALL stay in process memory or tmpfs", Decision 4 "do not write
it into the virtio-fs rootfs (snapshots would clone the PAT)") land
in the `.mem` artifact.

Consequences the design must own:

- The fat-agent scenario is literally true (rootfs is clean) and
  materially misleading: a memory snapshot of Z after redeem holds
  the PAT on host disk under `@snapshots/`, outside the vault, with
  no 0600 contract and in scope for the future `@snapshots` →
  B2 work (`mjolnir-qwp`).
- Decision 5 (reuse until TTL or holder rotation) is voided by
  thaw: a thawed Z has the PAT without redeeming, after `exp`,
  after rotation. Revocation becomes "until someone thaws".

The system already has the seam. `MemorySnapshot.freeze` quiesces
`:managed`/`:persistent` VMs before pause so the LUKS DEK is not in
the RAM image (`memory_snapshot.ex:263-276`, `:quiesce_fun`). A
redeemed foreign secret is the same class of RAM-resident material
and the design does not mention freeze at all.

Owed: Decision 4 names `mj freeze` as a copy-out sink and picks one
of (a) quiesce: holders drop redeemed secrets on the freeze
quiesce hook, re-redeem after thaw (Decision 5 already permits
reuse); (b) `.mem` of a VM that has redeemed is declared
secret-bearing and handled like the vault; or (c) accepted
explicitly, with the Decision 5 caveat written down. Add one
scenario under "Copy-out is v1" for the memory-snapshot case and
cross-reference `vm-freeze`. Dormancy is filesystem-only
(`vm.ex:1259-1262`) and is not affected.

## Steelman against send-back

Strongest case for accept: both findings are about host plumbing
around the vault, the delta SHALLs are all still true as written,
and two other-family accepts already stand. Prior Fable, opus, and
sol all framed no-write-to-rootfs as "consumer discipline the host
cannot enforce" and moved on.

Why it does not hold: finding 1 is not consumer discipline, it is
the host's own timer exfiltrating the vault, and it is decided by
one line in Decision 1 (which root). Finding 2 is a folded living
spec from the same day contradicting the design's stated leak
model; the design's rationale for RAM-not-rootfs is false against
it. An architecture write whose rejected-option reasoning applies
harder to its chosen option is not ready to `act` from. Both
amends are a paragraph each and change no wire format.

## Non-blocking notes (implementing nodes)

- N1. Nonce store is lost on Elixir restart; that is fail-closed
  and correct. Say so in `add-tokenator-redeem` so nobody makes it
  durable.
- N2. `put_opaque` does not fsync (sol N1). Same fix as envelopes.
- N3. Redeem must be guest TCP to `api_url`, never wrapped in
  `mj exec` (stdout is logged). One sentence in the redeem node.
- N4. `tasks.md` still carries the pre-amend "vault is owner
  envelope" box as `[x]` (sol N5). Strike or annotate on amend.

## Claims verified against code

- `secret_store_root` = `btrfs/@sites/keyspace` (`config.exs:124`);
  opaque path `_opaque/<kind>/<id>/<key>` (`secret_store.ex:498-499`);
  0600, no fsync (`:155-168`).
- `backup-sites-b2.sh` copies `@sites` wholesale, excludes only
  `plaintext-cache/**`, append-only, `hard_delete=false`.
- `secret_escrow_dir` outside `btrfs_root` on purpose (`config.exs:34-38`).
- `MemorySnapshot.memory_dir` = `@snapshots/<name>.mem`; `fork_dir`
  = `@snapshots/<name>.mem.forks/<id>`; quiesce for
  `:managed`/`:persistent` only.
- `handle_done` → `do_snapshot` (filesystem), RAM dropped.
- `@skip_auth_paths` is `/api/health` only; sites tokens before
  loopback bypass (`auth.ex:34, 49-63`).
- No Blake3 dep in `mix.exs` (`:78-81`).

## Verdict

Send-back. Two owed boxes on `tasks.md`, each a one-paragraph amend
plus one scenario. Shape (opaque vault, salted Blake3, redeem on
`api_url`, fourth Auth branch, holder-plus-bearer, copy-out
superset) stands. Banner stays `ACTIVE BUILD`. Do not implement
from this review.
