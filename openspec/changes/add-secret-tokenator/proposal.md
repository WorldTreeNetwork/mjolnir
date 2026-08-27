# add-secret-tokenator

> **ACTIVE BUILD**

Activated from intend 2026-08-26 (`nod-tokenator-design`,
`mjolnir-axsb.1.2`). Depends on `update-identikey-capability`
(`mjolnir-axsb.1.1`).

**Rigor:** architecture

## Why

Intermediate agents must carry a Biscuit, not a GitHub PAT. The
protocol names holder-bound redeem. Mjolnir is the first verifier:
it already stores opaque secrets (`SecretStore.put_opaque`) and
already exposes a guest-reachable API on `host_api_ip`. Without this
capability the protocol has nowhere to land.

## What

- Add capability `secret-tokenator`: owner deposits a foreign secret
  into SecretStore opaque; mint a holder-bound Biscuit that names it;
  `POST` redeem with Biscuit + holder proof returns the secret to
  that key only.
- Accept ADR 0008 (`docs/decisions/0008-secret-tokenator.md`, full
  text in `design.md`).
- This change is the architecture write (ADR + deltas). Code is
  `act` of later nodes after advise accept (`add-biscuit-runtime`,
  `add-tokenator-redeem`, `add-capability-mint`, `add-capability-hop`).

## Impact

- Capabilities: ADDED `secret-tokenator` (materialized by fold)
- ADRs: 0008 (this change). Pointer from `docs/architecture.md` after
  accept.
- Does not add a new sidecar port. Redeems on the existing API
  (`api_url` in `vm.json`).
- Does not replace JWT VM scopes (rbac-design Phase 1).

## User journey & surfaces

No new UI because the outcome already reaches `mj` / `POST` on
`api_url` (Papyrus mint UI is roster A).

Owner has a GitHub PAT. Agent Z must `git push`. Agents A–C are in
the way:

- **Working (after later act)** — owner deposits PAT; mints a
  Biscuit for Z's public key; A–C pass the Biscuit (mailbox);
  Z `POST /api/secrets/redeem`; Z holds the PAT in RAM; A–C never
  saw it.
- **Empty** — `openspec/specs/secret-tokenator/` does not exist yet.
  Correct: fold creates it.
- **Failed (today)** — PAT is copied into the spawn env or a chat.
- **Off** — Duke parks. ADR is amended in place, not deleted.

## Out of scope

- Protocol holder/hop text — `update-identikey-capability`
- Biscuit NIF / authority key — `add-biscuit-runtime`
- HTTP redeem implementation — `add-tokenator-redeem`
- Mint CLI/API implementation — `add-capability-mint`
- Per-hop signed blocks — `add-capability-hop`
- Papyrus UI — `mjolnir-axsb.2`
- Guild membership checks
- Recrypt PRE of the PAT
- GitHub-side proxy (v1 returns the PAT bytes)
- VM-exec Biscuit (rbac Phase 1)
