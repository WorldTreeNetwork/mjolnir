# Design — secret tokenator (foreign secrets)

Canonical ADR index:
[`docs/decisions/0008-secret-tokenator.md`](../../../docs/decisions/0008-secret-tokenator.md).
This file is the full argument. Protocol decisions live in
[`../update-identikey-capability/design.md`](../update-identikey-capability/design.md).

**Status:** Proposed. ACTIVE BUILD. Fable accept-with-nits
2026-08-26. Human amend same day: Blake3, salted commitments,
Gordian envelopes deferred.
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

## Decision 1 — Opaque vault; salted Blake3 commitment; Gordian later

v1 does **not** wait on Gordian envelopes. `SecretStore.put` still
JSON-decodes (`verify_envelope/2` → `:bad_envelope_json` on dCBOR).
Duke 2026-08-26: put envelopes off; keep copy-out verifiable.

Store:

```
_opaque/secrets/<secret_id>/value   # PAT bytes, 0600
_opaque/secrets/<secret_id>/meta    # owner fp, salt, commitment, label
```

`put_opaque/4` is the API (Buzz nsec precedent). Guests cannot
write this namespace. `secret_id` is path-safe. Owner deposits
through authenticated host API (JWT / localhost today).

**Commitment (travels; secret does not):**

```
salt       := 32 CSPRNG bytes          # public, stored in meta, on the token
commitment := Blake3( domain || salt || secret )
domain     := "mjolnir/secret-commit/v1"
```

Copy-out returns `{value, salt}`. Recipient checks
`Blake3(domain || salt || value) == commitment`. A value that
does not match is not this token's secret.

**Salt is mandatory** on any hash of a secret that leaves the
vault (token, mailbox, log, elision digest). An unsalted hash of
a PAT is a lookup table. When Gordian envelopes return, assertion
elision SHALL be salted the same way — not an unsalted digest of
the PAT bytes.

**Blake3 is real Blake3**, not `Sites.Crypto.blake3_hash/1` (that
function is SHA-256 today, `crypto.ex:24-29`). Holder fingerprints
are auth-challenge v1 §5: `Blake3(dcbor({alg, key}))`, not
`IdentiKey.fingerprint/1` (raw Ed25519, stub hash). Those two
preimages stay distinct until a dedicated Sites cutover. Wiring
the NIF is `add-biscuit-runtime`. Do not migrate existing
SecretStore directory names in this change.

Rejected as vault:

- **Gordian envelope in v1.** Right shape later; `put/3` cannot
  hold dCBOR today. Deferred, not rejected forever.
- **Unsalted hash of the secret on the wire.** Dictionary.
- **Env files in the rootfs.** Cloned by every snapshot.
- **Mailbox payload.** Then the PAT *is* what travels.
- **Recrypt PRE of the PAT.** D-5 stays for *our* objects.

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
4. Host verifies signature, computes Identikey fingerprint
   (auth-challenge §5, real Blake3), injects `holder(<fp>)`,
   evaluates Biscuit, `get_opaque` the value, returns
   `{value, salt}`.
5. Recipient checks
   `Blake3("mjolnir/secret-commit/v1" || salt || value)`
   against the commitment on the token.

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

v1 **copy-out** returns `{value, salt}` to Z. Z checks the
salted Blake3 commitment on the token. Copy-out is the
**superset**: a thin-proxy agent can be the only holder and make
the upstream call; fat agents never redeem. That proxy is the
more secure pattern. It is not required to start. A v1 that
forbids copy-out is rejected; a v1 that omits the pattern from
the design is also wrong.

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
- **Unsalted elision / unsalted Blake3 of the PAT.** Always salt.
