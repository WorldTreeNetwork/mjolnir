# update-identikey-capability

> **ACTIVE BUILD**

Activated from intend 2026-08-26 (`nod-cap-profile`, `mjolnir-axsb.1.1`).
Dossier: Papyrus `docs/notes/2026-08-26-ultimate-hammer.md`.
Protocol file that this folds into:
`~/work/IdentiKey/identikey-protocol/docs/standards/identikey-capability-v1.md`.

**Rigor:** architecture

## Why

A working secret (GitHub PAT, API key) must not travel down an agent
tree. The protocol already named Biscuit as agency and Recrypt PRE as
data access, but it does not yet say how a token is bound to the
*using* key, how hops are proven, or why a tokenator is allowed for
foreign secrets without undoing Recrypt D-5.

## What

- Amend capability `identikey-capability` (protocol-tier spec, not a
  Mjolnir living spec): holder-bound Biscuit; hop provenance is the
  Biscuit block chain; a **secret-redemption profile** for foreign
  secrets; guilds named and not built.
- Keep the three layers. Tokenator is a *verifier application* of
  agency, not a fourth crypto layer.
- This change is the architecture write (design + deltas). Copying
  into `identikey-capability-v1.md` is `act` after advise accept.

## Impact

- Capabilities: MODIFIED `identikey-capability` (materialized by
  folding into the protocol spec)
- ADRs: none in Mjolnir. Protocol decisions live in `design.md` and
  then in `identikey-capability-v1.md`.
- Does not rewrite Recrypt D-5. Does not add a Biscuit crate.

## User journey & surfaces

No new UI because the outcome already reaches the protocol spec
(`identikey-capability-v1.md`) and, after later nodes, `POST` redeem
/ `mj cap mint`.

An owner issues a GitHub PAT into SecretStore, mints a Biscuit for
agent Z's public key, and hands the Biscuit to agent A:

- **Working (after later act)** — A, B, C pass the Biscuit; only Z
  redeems; the PAT never appears in A's, B's, or C's memory.
- **Empty** — protocol spec has three layers and no holder/hop/redeem
  profile. Correct until fold.
- **Failed (today)** — the only way to give Z GitHub access is to
  copy the PAT down the tree.
- **Off** — Duke parks. Design is amended in place, not deleted.

## Out of scope

- Tokenator sidecar / NIF / HTTP — `add-secret-tokenator`
  (`mjolnir-axsb.1.2`)
- Host mint/verify runtime — `add-biscuit-runtime` (`mjolnir-axsb.1.3`)
- Guild / keyspace membership as holder class — named here, not built
- VM-exec Biscuit (rbac-design Phase 1)
- Papyrus mint UI (roster A, `mjolnir-axsb.2`)
- Test vectors — `ikp-6yz.2`
- identikey-log as a second provenance
