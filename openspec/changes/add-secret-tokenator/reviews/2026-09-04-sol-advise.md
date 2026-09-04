# Advise — add-secret-tokenator (architecture)

> **ADVISE:** accept
> **READER:** sol-arch-review
> **SPAWN:** .spawns/advise-add-secret-tokenator-sol-1788532385-417748-4b193747

Reader: sol-arch-review (other-family; author family is Grok; ADR-005).
Rigor: architecture. Scope: ADR 0008 + deltas, not unwritten HTTP/NIF/CLI.
A 2026-09-04 opus-4.8 accept already exists; this is the second other-family
read because Fable 5.1 could not run. Fable's 2026-08-26 accept-with-nits
reviewed the pre-amend envelope vault; this read is of the post-amend
opaque + salted Blake3 text.

## Blind pass (Why + living spec + ADR 0008 + `put_opaque/4`, before design.md)

Written independently, then compared. Concerns the author must have answered.

1. Commitment and holder fingerprint must be real Blake3. `Sites.Crypto.blake3_hash/1`
   is SHA-256 (`crypto.ex:24-29`). Using it here is a wire break, not a stub to
   paper over.
2. Redeem proof: server nonce, single-use until `exp`, signature covering token
   identity (and audience). Bytes-only Biscuit must fail closed.
3. Deposit is owner-only. "Guests SHALL NOT write `_opaque/secrets/`" is an HTTP
   property: no guest-reachable deposit, and a redeem Biscuit must not confer one.
   `put_opaque` itself is just a host function (`secret_store.ex:155-168`).
4. Copy-out is verifiable: recipient checks `Blake3(domain||salt||V)==C`. Salt
   travels; secret does not. Unsalted `Blake3(secret)` is a lookup table.
5. Refuse: SHA-256 stub as Blake3; redeem on `@skip_auth_paths`; new overlay
   port + `tokenator_url`; Recrypt ciphertext in this vault.
6. Tradeoff: v1 copy-out to a fat holder vs thin proxy. Copy-out is the smaller
   start and the primitive the proxy is built from. Post-redeem the host cannot
   stop Z writing the PAT onto virtio-fs.

## Steelman — how the design answers each

- **(1)** Decision 1 pins real Blake3 and sends NIF wiring to `add-biscuit-runtime`.
  Spec rejection scenario "SHA-256 stub used as Blake3" is the gate on 1.4/1.5.
- **(2)** Decision 3: `POST /api/secrets/challenge` → `{nonce, aud, exp}`; holder
  signs `{biscuit_hash, nonce, aud}`; reused nonce fails closed (spec scenario).
  Follows protocol Decision 3. Stronger than the blind take (audience too).
- **(3)** Owner deposits on JWT/localhost. Fourth `call/2` branch confers redeem
  and challenge only (`design.md` Decision 2; spec skip-auth rejection). Guests
  on `10.200.0.1:4000` do not get loopback bypass (`auth.ex:139-143`).
- **(4)** Domain `"mjolnir/secret-commit/v1"`, 32-byte CSPRNG salt, copy-out
  `{value, salt}`. Unsalted-hash and unsalted-elision rejection scenarios exist.
  Gordian deferred; when it returns, elision is salted the same way.
- **(5)** All four refusals are spec rejection scenarios plus design Rejected
  lists. Recrypt PRE stays D-5 (`spec.md` "Recrypt data is not this vault").
- **(6)** Decision 4 names copy-out as the v1 superset and the thin proxy as the
  more-secure pattern, not v1-required. RAM/tmpfs constraint is named; the spec
  admits the host cannot enforce it ("unless Z wrote them there in violation").

Layout matches code: `get_opaque("secrets", id, "value")` is
`_opaque/secrets/<id>/value` (`secret_store.ex:498-499`). `kind="secrets"` does
not collide with Buzz `_opaque/vms/<id>/`. `validate_opaque_segment/1` rejects
`/`, `..`, NUL (`:502-508`). 0600, no envelope (`:149-168`).

Every 2026-08-26 send-back that still applies (Auth fourth branch, holder fp
encoding, reused nonce, copy-out not virtio-fs) is in the deltas. The envelope
send-back was reversed by the human amend (Gordian deferred because `put/3`
JSON-decodes and rejects dCBOR — `secret_store.ex:600-602`). Current
proposal / spec / ADR / design all agree on opaque + salted Blake3.

## Non-blocking notes (implementing nodes, not owed here)

- **N1 — fsync on opaque writes.** Envelope `write_atomic` fsyncs
  (`secret_store.ex:548`). `put_opaque` is `File.write` + chmod + rename, no
  sync (`:160-166`). Same as Buzz nsec. `add-capability-mint` should fsync the
  PAT the way envelopes already do. Not a vault-shape issue.
- **N2 — Biscuit branch ordering.** Sites tokens are checked *before*
  localhost bypass so a narrow credential is not upgraded (`auth.ex:20-24,
  49-63`). The fourth branch needs that slot: a Bearer Biscuit from `127.0.0.1`
  must get redeem-only, not `@all_scopes`. Spec requires conferral; act node
  (`add-tokenator-redeem`) pins order.
- **N3 — challenge credential + nonce-store bounds.** Challenge happens before
  a holder signature exists. Present the Biscuit at challenge; bound the store
  (stolen bytes must not be an unbounded nonce mint). Fable nit 4; still an
  `add-tokenator-redeem` pin, not a missing SHALL.
- **N4 — host-global `secret_id`.** Opaque path is not keyed by identikey_fp.
  `meta` holds owner fp, but `put_opaque` will overwrite. `add-capability-mint`
  must refuse deposit/mint/list unless the caller matches `meta.owner_fp`.
  Today's JWT already grants full control-plane scopes; this is the Policy
  analog, not a new vault.
- **N5 — `tasks.md` history.** The checked box "vault is owner envelope, not
  host-global opaque" describes the pre-amend send-back, not the current
  design. Harmless if the executor reads `design.md`. Do not treat it as a
  SHALL.

None of N1–N5 change the architecture or the delta.

## Claims verified against code

- `put_opaque/4` / `get_opaque/3` exist; 0600; unsigned (`secret_store.ex:148-185`).
- Opaque path `_opaque/<kind>/<id>/<key>` (`:498-499`).
- `@skip_auth_paths` is only `/api/health`; `/auth/*` is a prefix skip
  (`auth.ex:34, 66-68`). No biscuit branch yet — that is the act node.
- Guest `:4000` is not loopback bypass (`auth.ex:139-143`; `vm.json` `api_url`
  is `http://10.200.0.1:4000`).
- `Sites.Crypto.blake3_hash/1` is SHA-256 (`crypto.ex:24-29`).
- `IdentiKey.fingerprint/1` is base58 of that stub over raw Ed25519
  (`identikey.ex:75-77`) — distinct preimage from auth-challenge §5.
- Envelope `put/3` cannot hold unsigned PAT bytes (LEARNINGS mjolnir-1pe;
  `verify_envelope/2` at `:599-618`).
- No `tokenator_url` in `configure_identity` (`vsock/protocol.ex:183-191`).
- Bandit has no extra overlay port today (`application.ex:112-115`).

## Verdict

Accept. The architecture write is internally consistent after the Gordian
deferral; the delta SHALLs are testable; each risky choice has a rejection
scenario for later acts. No owed boxes. Do not fold unimplemented HTTP SHALLs
into the living spec until the matching act lands (learning 2026-08-16).
