# advise (fold) add-honor-git-remote — 2026-09-24

> **ADVISE:** send-back
> **READER:** opus-5-fold-reader
> **SPAWN:** /Users/dukejones/work/IdentiKey/mjolnir/.spawns/add-honor-git-remote-1790266801-15570-61c83e77

Reader pass on the **fold** packet `pkt-fold-add-honor-git-remote`, not on
the plan. Rigor: change. Read blind first (proposal `Why`, the living
`openspec/specs/honor-being/spec.md`, `lib/mjolnir/git_signing.ex`,
`lib/mjolnir/forgejo/deploy_keys.ex` at `0809478`, the `git_signing`
call sites in `lib/mjolnir/vm.ex`, `scripts/hosted-being-bootstrap.sh`,
ADR 0011), wrote the take below, then opened `design.md`, `tasks.md` and
the delta.

The craft here is good — custody split, revoke ordering, 404-is-success,
delete-by-pubkey fallback, `safe_body/1`, `IdentitiesOnly` +
`StrictHostKeyChecking=yes` with a pinned mimir host key, 13 green tests
that map one-to-one onto the SHALLs. Send-back is not about any of that.
It is that **two of the SHALLs about to become living are not true of the
landed code**, and one of them is a live write credential on the prod
storefront repo. Both are small fixes; neither needs a redesign.

## Blind take (written before design.md / tasks.md / the delta)

1. PIN write scope: the key must be a *repo* deploy key with
   `read_only: false`, never a user-level SSH key — a user key writes
   every repo that user can touch. (`deploy_keys.ex:88` — correct.)
2. PIN a deterministic title carrying `vm_id`, so a leftover key is a
   named reconcile find rather than an anonymous one.
3. PIN revoke order Forgejo-first, and a failed Forgejo delete stops the
   chain with the opaque intact — you must never drop the only pointer to
   a live write credential.
4. REFUSE `:not_wired → :ok` in prod. The `Why` says that mapping "is no
   longer the configured path", but the code still maps it. If prod loses
   `MJOLNIR_FORGEJO_TOKEN`, every respawn silently leaves a live write key
   — exactly the inverse failure the `Why` names. Something must assert
   the token in prod, or surface undeleted keys.
5. PIN the A3 gate on *registration*, not just on the identikey row.
   `mint/1` registers before any xid exists; a VM that never becomes a
   hosted being can still end up holding prod write.
6. REFUSE a Forgejo token or PAT in the guest, and refuse a machine user
   (ADR 0011: the VM is a device, not a second person). Both held.
7. PIN guest SSH: host-scoped `IdentityFile` + `IdentitiesOnly=yes` +
   pinned `known_hosts` for mimir, else the first push TOFUs or prompts.
   (Bootstrap does all three.)
8. PIN that one key serves sign *and* push, said out loud — rotation is
   then atomic, but revoking push also revokes the signing identity.
9. TRADEOFF: deploy key means Forgejo shows the push unverified, so
   authorship lives only in identikey, not in the mimir UI. Worth it;
   a machine user costs a second identity, which ADR 0011 forbids.
10. NOTE the blast radius: any process in the guest — including grok, an
    LLM — can push `main` of the prod frontend, and `deploy.yml` cuts
    over prod. `ENABLE_DEPLOY` is then the only live brake.

## Compare

Takes 1, 2, 3, 6, 7, 8, 9, 10 are all answered, most of them better than
I framed them. Design Decision 2 answers 4 in prose ("prod hosted-being
provision requires the token") and Decision 1 answers 5 by listing
"Deploy key with no `ssh_git` row" under **Rejected**. The problem is
that neither answer reached the code or the delta, and the fold is what
makes the delta binding.

## Blocking

**B1 — the ADDED requirement is not true as written.** The delta says the
deploy key's "public key is the identikey `ssh_git` `device_public_key`",
and `design.md` Decision 1 rejects a deploy key with no `ssh_git` row.
As landed, `GitSigning.mint/1` writes device meta with `public_key` only
(`git_signing.ex:79`), then `forgejo_register/2` reads `xid` back and
gets `nil` (`:184`). Nothing in `lib/` ever calls `put_device/2` with an
`xid` or `credential_id` — grep is empty outside the module itself. So
every registered key is titled `mjolnir ssh_git <vm_id>` with no xid and
no identikey row behind it, and `POST /api/vms {"git_signing": true}`
(`router.ex:277`) grants prod-frontend write to any caller who can spawn.
The living requirement "No implicit device without A3 consent" still
holds for the `ssh_git` row, but the Forgejo write key now escapes it.
Smallest fix: gate `forgejo_register/2` on a present `xid`, or — if the
author holds that the A3 gate lives upstream in provisioning — say so in
the requirement and add the negative scenario (no A3 → no deploy key),
so the fence is a SHALL and not a convention.

**B2 — the MODIFIED requirement's middle step cannot fire.** Both the
already-living text and the delta name the order "Forgejo delete →
`revoke_device` → opaque". `identikey_revoke_device/1` short-circuits to
`:ok` whenever `credential_id` or `xid` is not a non-empty binary
(`git_signing.ex:216`) — which, per B1, is always, for every real VM.
The passing test at `git_signing_test.exs:87` hand-seeds both fields;
the product never does. Folding this sentence puts a step into the living
spec that no VM executes. Either wire the producer, or fold the clause
with the gap named (a `#### Scenario` for the never-registered case
already exists implicitly in the code comment — make it explicit).

## Notes (not blocking)

- N1 — `:not_wired → :ok` on revoke is right for dev/test and wrong
  unnoticed in prod. There is no assertion anywhere that prod has the
  token, and the `terminate/2` call site discards the result entirely
  (`vm.ex:1897`, `_ = GitSigning.revoke(...)`), so a failed delete is
  silent: no log, no event, no queue. "Reconcile find" names a reconciler
  that does not exist. A `Logger.warning` on `{:error, _}` there is one
  line and makes the find findable. Worth a follow-up bead, not a gate.
- N2 — The ADDED SHALL gives the remote as
  `forgejogit@mimir.worldtree.network:...`, but bootstrap rewrites that
  to `git@` via two `url.insteadOf` rules (`hosted-being-bootstrap.sh:53`).
  The `forgejogit@` URL never reaches the wire. Keep it if it is the
  spec-facing name, but the living spec should not read as if it is the
  transport.
- N3 — `title/2`'s `xid` branch is dead for the same reason as B1; it
  becomes live for free once B1 is fixed.
- N4 — ADR 0011 and `docs/architecture.md` need no shape change for this
  landing. ADR D4/D7 already describe it; leave them.

## Would accept on

B1 and B2 resolved in-fold, either by a guard or by delta wording that
makes the real boundary a SHALL. Everything else in this change is ready
to be living truth.
