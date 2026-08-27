# Design — secret tokenator (foreign secrets)

Canonical ADR index:
[`docs/decisions/0008-secret-tokenator.md`](../../../docs/decisions/0008-secret-tokenator.md).
This file is the full argument. Protocol decisions live in
[`../update-identikey-capability/design.md`](../update-identikey-capability/design.md).

**Status:** Proposed. ACTIVE BUILD. Advise not yet accepted.
**Change:** `add-secret-tokenator`
**Epic:** `mjolnir-axsb.1`
**Bead:** `mjolnir-axsb.1.2`
**First consumer:** a guest agent that needs a GitHub PAT (or any
API key) without the parent agents holding it.

Grok authored. Advise reader must not be Grok (ADR-005). Fable 5 is
the cross-family reader. Sol is not subscribed.

## Problem

Four questions after intend:

1. Where does the PAT live?
2. Where does redeem run — new sidecar port, or the existing API?
3. How does Z prove it is the named holder?
4. Is it honest that this service sees every redemption?

## Decision 1 — Vault is an owner-signed Gordian envelope (elided in flight)

The PAT is an **assertion** on a Gordian envelope signed by the
owner Identikey. At rest the assertion is present. In flight it is
**elided**: the digest remains, the bytes do not travel. On
copy-out, the recipient verifies the returned value against that
digest. That is what elision is for (`identikey-log` already
skips elided assertions and counts them; the envelope digest is
elision-stable).

Store: `SecretStore.put(identikey_fp, "secrets/<secret_id>",
envelope_bytes)` — the envelope API, keyed by owner, not
`put_opaque`. Opaque stays for unsigned VM material (Buzz nsec).
A PAT wrapped in a signed envelope is not unsigned.

Signature verification on SecretStore is still stubbed
(`verify_envelope/2`). Named hole: once MultiSig is wired, deposit
and redeem SHALL fail closed on a bad owner signature. Until then
this vault inherits the same stub as site HEADs. Do not pretend
it verifies today.

Guests cannot write this keyspace. Owner deposits through
authenticated host API (JWT / localhost today). `secret_id` is
path-safe (no `/`, `..`). The vault is **per-owner** (envelope
keyspace), not host-global opaque.

Rejected as vault:

- **Raw `put_opaque` without an envelope.** No digest to check the
  copy-out against the token.
- **Env files in the rootfs.** Visible to every process in that
  guest, cloned by every snapshot.
- **Mailbox payload.** Then the PAT *is* what travels.
- **Recrypt PRE of the PAT.** GitHub issued plaintext. D-5 stays
  for *our* objects.

## Decision 2 — Redeem is on `api_url`, not a new sidecar port

Blob door is a separate port because it must not bounce Elixir and
it does not read OTP state. Tokenator **does** read SecretStore
(Elixir). A second binary that opens the same 0600 files is a
permissions and locking mess.

Redeem:

```
POST {api_url}/api/secrets/redeem
```

Body: Biscuit + holder proof. The Biscuit *is* the authorization.
No JWT required on redeem (the using agent often has none).

Locator: existing `api_url` in `/etc/mjolnir/vm.json`. Do not add
`tokenator_url`. Do not bind `0.0.0.0`. Guest TCP remains INPUT on
`host_api_ip` (same trap as :4000 / :7222 / :5432).

Installing this feature **does** restart Elixir (`just deploy`).
That is accepted. Do not invent a just verb. Do not make a systemd
unit that duplicates SecretStore.

Mint/list stay on the same API, owner-authenticated.

Auth plug (`Mjolnir.API.Auth`): redeem and challenge are a
**fourth `call/2` branch**, same idea as sites tokens — presenting
this credential confers *only* redeem (and the challenge that
serves it). SHALL NOT add `/api/secrets/*` to `@skip_auth_paths`
(`lib/mjolnir/api/auth.ex:34`). A skip-auth redeem is an
unauthenticated route whose fail-closed lives only in handler
code. Sites tokens exist so a narrow credential is not upgraded.

## Decision 3 — Holder proof is a signature at redeem time

Follow protocol Decision 3. Concrete wire (v1):

1. `POST /api/secrets/challenge` → `{nonce, aud, exp}` (`aud` is
   this API). Nonce is single-use until `exp` (auth-challenge v1
   nonce store). Reuse fails closed, no secret.
2. Holder signs canonical bytes of `{biscuit_hash, nonce, aud}`.
3. `POST /api/secrets/redeem` with `{biscuit, alg, public_key,
   signature, nonce}`.
4. Host verifies signature, computes Identikey fingerprint,
   injects `holder(<fp>)`, evaluates Biscuit, loads the owner's
   envelope, returns the secret assertion.
5. Recipient checks the value against the elided digest on the
   envelope the token committed to.

Reuse identikey-auth challenge shapes where they already match
(audience, nonce, exp). Do not put `resources` on that challenge.
The grant is the Biscuit.

Rejected:

- **Bearer Biscuit only.** Stolen bytes would redeem.
- **TLS client cert as the only holder proof.** Fine later; not v1.
- **Self-asserted `agent_type` string.** Verifier-injected catalog
  fact, if ever — not a token claim.

## Decision 4 — Tokenator seeing redemptions is accepted and named

This service learns that Z redeemed secret S at time T, and it
handles PAT bytes. That is the D-5 objection to tokenator-as-
authority. It applies, and we take it, **only** because the payload
is a foreign secret. Log redemption metadata (secret id, holder
fingerprint, time, result). Never log `value`.

v1 **copy-out** returns the PAT bytes to Z (plus enough envelope
to verify the digest). Copy-out is the **superset**: a thin-proxy
agent can be the only holder and make the upstream call; fat
agents never redeem. That proxy is the more secure pattern. It is
not required to start. A v1 that forbids copy-out is rejected; a
v1 that omits the pattern from the design is also wrong.

Copy-out into Z: keep the value in process memory or tmpfs. Do
not write it into the virtio-fs rootfs (snapshots would clone the
PAT). The thin proxy is how you avoid that class of leak without
giving up copy-out for ease of use.

## Decision 5 — Reuse until TTL or holder rotation; single-use is a check

v1 tokens are reusable until a time check fails or the holder key
is rotated (old key stops satisfying the holder proof). Single-use
or N-use is a Datalog check plus a stateful fact the host injects
(`redeem_count`). Not in the first act. Do not build a second
ledger for it until someone needs it.

## Decision 6 — Code splits stay the intend nodes

This architecture change does not implement:

| Node | Landing |
|---|---|
| NIF + authority key | `add-biscuit-runtime` |
| Challenge + redeem HTTP | `add-tokenator-redeem` |
| Deposit + mint | `add-capability-mint` |
| Append block per hop | `add-capability-hop` |

Fold of *this* change creates `openspec/specs/secret-tokenator/`
from the deltas. Those later changes MODIFY or act against that
living spec. Do not import unimplemented HTTP SHALLs into the
living spec until the matching act has landed (learning
2026-08-16, architecture-plus-one-slice).

## Rejected

- **New port :72xx for tokenator.** SecretStore is in-process.
- **Elixir Port to a biscuit CLI per request.** NIF or a long-lived
  Rust sidecar that talks to Elixir over localhost is the runtime
  node's choice; this design only forbids a guest-visible extra
  overlay port and forbids a second vault.
- **Putting the PAT in the Biscuit authority block.** Protocol
  Decision 2.
- **Forbidding copy-out in v1** (proxy-only). Copy-out is the
  superset; proxy is a consumer of copy-out, not a replacement.
