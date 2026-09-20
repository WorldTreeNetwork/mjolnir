# advise (fold) add-honor-dev-preview — 2026-09-19

> **ADVISE:** accept
> **READER:** opus-5-fold-reader
> **SPAWN:** /Users/dukejones/work/IdentiKey/mjolnir/.spawns/add-honor-dev-preview-1789862103-86025-45882c76

Reader pass on the **fold** packet `pkt-fold-add-honor-dev-preview`, not
on the plan. Rigor: change. Read blind first (proposal Why/What, the
delta `specs/honor-being/spec.md`, the absent living spec, ADR 0011,
`docs/architecture.md` §hosted being, and the landed code at `bd6248b`:
`scripts/hosted-being-bootstrap.sh` + `docs/runbooks/hosted-being.md`),
wrote the take below, then opened `design.md` and `tasks.md`.

Accept: the delta is small, the SHALLs are true of the landed code, and
the scope fence (no passkey / ssh_git / Forgejo / CORS) is drawn in the
right place. Notes 2, 3 and 4 are edits the folder should make inside
this same fold; none of them is a send-back.

## Blind take (written before design.md / tasks.md)

1. PIN: living spec path is `openspec/specs/honor-being/spec.md`. It does
   not exist; ADR 0011 already links that exact path, so the fold creates
   it and later landings append to it. Capability dir stays `honor-being`
   even though the product is "hosted being".
2. PIN: folding one of five landings makes `docs/architecture.md` false —
   it currently says "Living spec waits on implement landings". That file
   is in `constraints.paths` for exactly this reason. Edit it in the same
   fold: seeded by this change, remaining SHALLs still waiting.
3. PIN: the `preserve_iroh_key` asymmetry deserves a SHALL and the delta
   does not have one. ADR 0011 D7 and the runbook both say: per-friend
   `hosted-<xid>` respawn preserves the Iroh key; a **shared** bootstrap
   snapshot MUST NOT (two VMs must not share a node id). That is the only
   invariant in this change with a real collision failure mode, and a
   strict delta-only fold drops it. The packet's own anchor asserts it.
   Carry it, or say in the fold note why it waits.
4. REFUSE the mechanism phrase "bound on `0.0.0.0`" as living-spec text.
   What actually decided this landing was guest port 80 plus
   `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=.vm.worldtree.network` — Vite 6
   rejects an unknown Host with 403, and `0.0.0.0` alone gets you a 403,
   not a 200. Keep the SHALL at outcome level ("the ticket URL loads it")
   and leave flags to the runbook; otherwise the spec is brittle and
   under-specified at the same time.
5. REFUSE importing what the code runs ahead of. `hosted-being-bootstrap.sh`
   already sets `gpg.format ssh`, `user.signingkey /run/mjolnir/git_signing_key`
   and `commit.gpgsign true`, but `add-vm-git-subkey` has not landed and the
   runbook admits the clone fails `Permission denied (publickey)`. Landed
   code is not a landed SHALL. No git-signing requirement in this fold.
6. PIN the tmpfs SHALL as a negative, host-checkable invariant — but note
   the code enforces less than the scenario claims. Bootstrap only refuses
   a `.env` containing `XAI_API_KEY`; grok's own config, shell history and
   anything written before snapshot are unguarded. Either scope the
   scenario to what is enforced, or file the gap.
7. NOTE: unauthenticated preview HTTP on the ticket origin is a deliberate
   stance (ADR 0011 D5, proposal "passkey gates `/term` only"). Say it in
   the living spec so a later fold cannot quietly assume auth there. The
   z32 ticket is the whole secret; that is a capability URL.
8. NOTE (cited-code defect, outside the folder's paths): the runbook's
   Bootstrap block shows `mj spawn --base ubuntu-24.04`, and its own last
   paragraph plus CLAUDE.md (`mjolnir-97c`) say `mj` has neither `--base`
   nor `--preserve-iroh-key` on 0.1.0. Two of three quickstart commands
   cannot run. Bead it; do not fix it in a fold.
9. TRADEOFF: `https://api.hypersigil.world` hardcoded into a *living*
   capability SHALL couples a generic hosted-being capability to one
   tenant's prod API. Correct and cheap for friend #1; wrong the day
   friend #2 arrives with a different backend. Accept knowingly.
10. Archive shape is right: `git mv` to
    `openspec/changes/archive/2026-09-19-add-honor-dev-preview`, ADR 0011
    text untouched. One LEARNINGS line is warranted — the Vite 6 Host
    check is a genuine surprise that cost a debugging cycle and will
    recur for every ticket-URL dev server.

## After reading design.md and tasks.md

The author answered more of the take than I expected. Steelmanning each:

**#3 (Iroh asymmetry) — answered, downgrade to a note.** I wanted a SHALL
the delta does not have. But ADR 0011 D7 already carries it in durable
text ("URL held by `preserve_iroh_key` from the per-friend snapshot
only"), the runbook states the shared-snapshot MUST NOT explicitly, and
the flag is pre-existing on `VM.spawn` / `POST /api/vms` — the runbook is
right that it belongs to the VM surface, not to honor-being. Not a fold
blocker. Still worth one sentence in the living spec, because an ADR and
a runbook are not a spec, and this is the only invariant here whose
violation is a node-id collision rather than a broken page.

**#9 (hardcoded prod API) — answered, no action.** tasks.md box 2 names
the URL as the deliverable and the Why says the friend needs *this* API.
Deliberate, not drift. Flagging it at friend #2 is the right time.

**#4 (`0.0.0.0`) — holds, with a correction to myself.** design.md
Decision 3 says "Vite binds `0.0.0.0`", so the delta's phrasing traces to
a decision rather than to sloppiness. `--host` genuinely is required. But
the landing proved it insufficient: without
`__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=.vm.worldtree.network` the ticket
Host gets a Vite 6 **403, not a 200**. Decision 3 is now stale against its
own landing. Don't delete `0.0.0.0` from the SHALL; add the ticket-Host
acceptance beside it, or the living spec describes a config that fails.

**#6 (tmpfs over-claim) — holds, unanswered.** tasks.md scopes the box to
"`XAI_API_KEY` documented as tmpfs-only (runbook)". The delta scenario
asserts something stronger and untested: that a mounted `hosted-<xid>`
snapshot *does not contain* the key. The code enforces exactly one thing —
a `.env` containing `XAI_API_KEY` is refused. grok's own config dir, shell
history, and anything written before `mj snapshot create` are unguarded,
and `acceptance.kind: none` means nothing checks. The author's box is
honest; the delta scenario is not. Fold it as written only if you are
willing to have a SHALL nobody verifies.

**#5 (git config ahead of spec) — holds, and it is worse than a spec
smell.** `hosted-being-bootstrap.sh` sets `commit.gpgsign true` globally
with `user.signingkey /run/mjolnir/git_signing_key`. `add-vm-git-subkey`
has not landed, so on a fresh guest that path does not exist and **every
`git commit` in the hosted being fails**. tasks.md has no box for git
config at all — this is creep from a sibling node that rode in on the
landing. Bead it; do not fix it in a fold.

**#8 — I was half wrong.** `--base` does exist (`main.rs:61-62`,
`api.rs:36`); `mjolnir-97c` is fixed and the runbook line is fine. But
`--preserve-iroh-key` appears **nowhere** in the client source, not merely
in the installed 0.1.0 binary. So the runbook prints, as its primary
respawn recipe, a CLI invocation that cannot work at any version — and
respawn is exactly the mechanism ADR 0011 D7 relies on for URL
preservation. The `POST /api/vms` form below it is the working one. Bead:
either add the flag or delete the CLI block.

**#2, #7, #10 — unaddressed by design/tasks, folder-actionable.**

## What the folder should do inside this fold

1. Create `openspec/specs/honor-being/spec.md` from the delta. Fence holds:
   no passkey, `ssh_git`, Forgejo, or CORS SHALLs.
2. Edit `docs/architecture.md` (~line 430) — "Living spec waits on
   implement landings" is false once this fold lands. Seeded by
   `add-honor-dev-preview` 2026-09-19; four landings still outstanding.
3. In the SHALL, put the ticket-Host acceptance next to `0.0.0.0`, and
   state that the ticket origin is unauthenticated HTTP (ADR 0011 D5).
4. Either narrow the snapshot scenario to the enforced `.env` guard, or
   keep it and open a bead for real enforcement.
5. LEARNINGS: one line, the Vite 6 Host check — `--host` alone yields 403
   on a ticket URL; the allowed-hosts env is what makes first paint work.

## Beads to open (not fold work)

- `commit.gpgsign true` in the bootstrap breaks `git commit` until
  `add-vm-git-subkey` lands.
- `mj spawn --preserve-iroh-key` does not exist in the client; runbook
  recipe is unrunnable.
- `XAI_API_KEY` tmpfs-only is documented, not enforced, beyond `.env`.
