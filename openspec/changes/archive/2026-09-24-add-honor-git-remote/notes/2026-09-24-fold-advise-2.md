# advise (fold) add-honor-git-remote — 2026-09-24 (second fold reader)

> **ADVISE:** send-back
> **READER:** opus-5-fold-reader-2
> **SPAWN:** /Users/dukejones/work/IdentiKey/mjolnir/.spawns/add-honor-git-remote-1790277514-33390-f3bb32a3

Reader pass on the fold packet `pkt-fold-add-honor-git-remote`. Rigor: change.
Read blind first — proposal `Why`, the living `openspec/specs/honor-being/spec.md`,
`lib/mjolnir/git_signing.ex`, `lib/mjolnir/forgejo/deploy_keys.ex`, the
`GitSigning` call sites in `lib/mjolnir/vm.ex`, `config/config.exs`,
`scripts/hosted-being-bootstrap.sh` — wrote the take below, then opened
`design.md`, `tasks.md`, the delta, and the two prior reviews.

The custody work is right and the fix commit `74ea6b4` is a real improvement:
registration is now gated, revoke fails closed on a recorded grant with no
token, delete-by-pubkey is the durable handle, repo/owner are config not
constants, and 15 tests are green (`mix test test/mjolnir/git_signing_test.exs`).
Send-back is not about the craft. It is that the gate closed the hole by
disabling the feature, and nothing in the repo re-opens it — so the headline
SHALL about to become living ("the host SHALL register … the being SHALL push")
has no producer, and the `Live:` box that would have proved it was checked
against pre-gate code.

## Blind take (written before design.md / tasks.md / the delta)

1. PIN registration on a real device row (xid + credential_id), never on
   "a VM asked for `git_signing`" — else any spawn earns prod push.
2. PIN revoke order Forgejo delete → `revoke_device` → opaque, with a failed
   Forgejo delete stopping the chain so the pointer survives.
3. PIN `:not_wired → :ok` only when no grant was ever recorded; a recorded
   grant with no token is an error. Fail closed.
4. PIN a pubkey fallback for delete when `key_id` was never persisted.
5. PIN the teardown call site: `vm.ex:1931` is `_ = GitSigning.revoke(...)`.
   A Forgejo outage at kill leaves a live prod write key, silently.
6. PIN that the living spec's own "have not landed and so are not SHALLs"
   paragraph and the "Forgejo key delete on revoke is `add-honor-git-remote`,
   not this requirement" sentence must go, or the fold contradicts itself.
7. REFUSE a Forgejo token or PAT in the guest; host-side registration only.
8. REFUSE a Forgejo machine user (ADR 0011: the VM is a device, not a person).
   Losing the "verified" badge is the correct price.
9. TRADEOFF: a repo write deploy key with no branch protection means anything
   in the guest — including grok — can push the prod cutover; bounded only by
   per-VM titled keys and `ENABLE_DEPLOY`.
10. WATCH two `present_id?` semantics: `GitSigning` accepts `"pending"`,
    `DeployKeys` requires digits. Consistent, but by construction not by name.

## Compare

Takes 1–4, 7–10 are answered, most better than I framed them. 1 is
`maybe_forgejo_register/2` (`git_signing.ex:181`) requiring nonempty `xid` and
`credential_id`; 2–3 are `forgejo_revoke/1` (`:204`) with the `grant?` guard;
4 is `delete_by_pubkey/2`; 9 is ADR 0011's accepted risk, correctly named
out of scope. 10 is deliberate: `"pending"` is a grant for fail-closed
purposes and not an id for the URL — worth one comment, not a change. 6 is
pure fold mechanics and unresolved only because the fold has not run.

Take 5 is still open (prior reader's N1): the `_ =` at `vm.ex:1931` means the
new fail-closed error is swallowed at teardown. Not blocking on its own.

## Blocking

**S1 — the ADDED requirement has no producer in this repo, and the evidence
for it predates the gate.**

The delta's first SHALL says the host "SHALL register and delete that key
through the Forgejo API" and that a hosted being "SHALL push" with it.
Registration now fires only from `put_device/2` once `xid` *and*
`credential_id` are on device meta (`git_signing.ex:181-190`). Nothing in
`lib/`, `scripts/`, the router, or `mj` ever writes those fields: `POST
/api/vms` takes only `git_signing: true` (`router.ex:277`) → `mint/1` →
`put_device(%{public_key: …})` (`git_signing.ex:79`). There is no
`/devices/ssh_git` *create* client — only the revoke half
(`git_signing.ex:280`). The 15 green tests hand-seed `xid`/`credential_id`
(`git_signing_test.exs:93,128,174,…`); the product never does.

So on today's `main`, a fresh hosted-being spawn still ends where the `Why`
starts: `Permission denied (publickey)`. The same gap keeps
`identikey_revoke_device/1` short-circuiting to `:ok` for every real VM —
the prior reader's B2, still true.

Timeline matters: `- [x] Live: clone/push … visible on mimir main` was checked
at `0809478`, the pre-gate commit where `mint/1` registered unconditionally.
`74ea6b4` changed exactly that path. The landed code has never been observed
to register a key.

`docs/runbooks/hosted-being.md:158` now tells the operator the false thing:
"Spawn with `git_signing: true` so mint registers the deploy key **before**
bootstrap clones." Post-gate it does not.

Smallest fix — pick one, both are small:

- **Own the seam.** Record `xid`/`credential_id` where the `ssh_git` row is
  created (an API/`mj` hook, or an explicit operator `put_device/2` step),
  correct the runbook to that step, re-run the live push on post-gate code,
  then fold with the `Live:` box honestly checked.
- **Or scope the SHALL.** Say in the requirement that registration is a
  provisioning step conditioned on the consented row, name the binding step
  as not-yet-wired in Mjolnir, uncheck `Live:`, and carry the producer as the
  next node. Then the living spec stays true.

What must not happen is folding the sentence as-is: it would make
"the host registers, the being pushes" living truth on a tree where no code
path registers.

## Notes (not blocking)

- N1 — `vm.ex:1931` discards `revoke/1`'s result. One `Logger.warning` on
  `{:error, _}` makes the "reconcile find" findable; without it, fail-closed
  is invisible at the only automatic call site. Follow-up bead.
- N2 — The delta names `forgejogit@mimir…` as the remote; bootstrap rewrites
  it to `git@` (`hosted-being-bootstrap.sh:53`). Fine as the spec-facing name,
  but the living text should not read as the transport. (Prior reader's N2.)
- N3 — `reviews/2026-09-24-advise-2.md` (astra) accepts *the contract for act*
  and says so explicitly: "not evidence that the current code satisfies them
  or that the change can fold … R1, R2, and R3 remain unchecked." The packet
  reads that accept as fold clearance. R1 landed as a guard; its producer
  half did not.
- N4 — ADR 0011 and `docs/architecture.md` need no shape change. Agree with
  the prior reader: leave them.

## Would accept on

S1 resolved either way — producer wired and re-verified live, or the SHALL
scoped to what is true with the gap named. Everything else here is ready to
be living truth.
