# What a dedicated `kind` claim requires at the pin

Facts for decision 1, written 2026-11-25. The owner chose the claim the same day. This note is now the
design input for that choice. Sources: pinned moq `4a6f522` (`rs/moq-auth`), `native/mjolnir_relay/src/lib.rs`,
jsonwebtoken 11.1.0, and the spike [`../spikes/claim-route.md`](../spikes/claim-route.md).

## (a) Can the relay accept an extra claim without patching moq-auth?

**Not as a top-level claim through moq-auth's verifier.** `KeySet::verify` → `Key::verify` →
`jsonwebtoken::decode::<moq_auth::Claims>` deserialises the payload through `wire::Claims`, which is
`#[serde(default, deny_unknown_fields)]` (`wire.rs:21`). The comment at `:47` says why: "an unknown one may
narrow the grant". `claims.rs:594` tests the refusal. The relay calls it at `lib.rs:233` (`assess`) for
WebTransport and, through `TokenPolicy`, for Iroh. Spike C1: a `kind` claim of any value is `BadToken` on the
production decider.

**What the decoder already tolerates** (spike C7, all admitted by today's production verifier and dropped):
- `sub` or `iss` holding a string. These are read as `IgnoredAny` (`wire.rs:49-52`). An object value is
  refused, by jsonwebtoken's own claim validation, before moq-auth sees it.
- A custom protected-header parameter. `jsonwebtoken::Header` collects unknown members in `extras`. The
  header is signed, so reading it after verification is sound.

None of these is a dedicated claim, and an old reader admits the token while ignoring the kind.

**Verify twice, or hand moq-auth a view without the claim:** moq-auth verifies the signature over the exact
token bytes, so it cannot be handed a stripped token without re-signing. It can be handed a stripped
*payload*. `moq_auth::Claims` implements `Deserialize` (strict, through the same `wire::Claims`), and
`Claims::validate`, `KeySet::find`, `Key::export`/`Deref<Jwk>` (algorithm, operations, scope, key material)
and `From<Algorithm> for jsonwebtoken::Algorithm` are all `pub`. So the relay can verify the signature itself
with the same jsonwebtoken and rind provider moq-auth uses, remove `kind`, and let moq-auth decode and validate
the rest. That is route (b). The spike proved it (C3–C6, C8). What it costs: Mjolnir owns the signature step
for room tokens (kid lookup, alg pin, key operations, scope refusal, `exp`/`nbf`) instead of moq-auth. Parity is
checked by a differential test against moq-auth's own corpus (`rs/moq-auth/tests/corpus.json`, shared with the
JS parser). No crate is added: jsonwebtoken and rind-jsonwebtoken are already in the relay lockfile.

**Carried patch (c):** add an optional `kind` to `wire::Claims` and `moq_auth::Claims` in a vendored copy,
`native/vendor/moq-auth/`, from `4a6f522`. Unlike `moq-webrtc` (`add-edge-keyframes` D4), moq-auth's manifest
uses `workspace = true` dependencies, so the vendored manifest is rewritten with explicit versions and with
the pinned git source for `kio`, `moq-crypto` and `moq-pattern`. Every graph that links moq-auth adds
`[patch."https://github.com/moq-dev/moq"] moq-auth = { path = … }`: the relay, the gateway (`.13`), and any
spike or harness that must agree. moq-relay itself depends on moq-auth, and the patch replaces it there too,
so each graph resolves one moq-auth. The relay's `Cargo.lock` entry for moq-auth changes from the git source to
a path, with the same version and no checksum. The E2EE work only signs test tokens; it needs the patch only
if it must emit `kind`. Upstream story: upstream refuses unknown claims on purpose, and a Mjolnir-named field
does not belong there. A generic "accepted extension claims" hook is the only shape that could be offered, and
nothing suggests it would be taken. The patch is carried on every pin move until then.

## (b) The durable store "one kind per owner and name" needs

A controller-side record keyed by `(owner, room)` holding the kind, the creation time and the latest `exp`
of any token minted for that room. It lives in a new root-only directory, `/var/lib/mjolnir/relay-rooms/`,
as one JSON file per room. The file is written as `Mjolnir.StateStore` writes: tmp, fsync, rename, then
fsync the directory. It does not live in `/var/lib/mjolnir/relay-mint` (that directory is the signing key's,
managed by `relay-mint-key.sh` under its flock), in `/etc/mjolnir-relay` (the relay's root-owned config, not
controller state), or in Postgres (`:pg_enabled` is optional, and by contract Postgres holds only derived,
rebuildable indexes). The record is created at the first successful mint, after every other check and before
signing. One serialising process decides, with an exclusive create for the first record, so two concurrent
first mints cannot both win. A room is live until its latest `exp`. After that, no token of the old kind can
be presented, so the name can safely take another kind. Whether to allow that reuse is the owner's ASK. The
files survive a controller restart and a hot cutover; the process re-reads disk. A second controller minting
for the same relay would need a shared store, such as Postgres with a unique key or a lease. Today a relay
host has one controller, so a room is effectively `(relay host, owner, name)`. Back the directory up with the
existing B2 timer. If the store is lost, the exposure lasts at most the token ceiling: a name could take the
other kind while old tokens live.

## (c) Deploy sequence, and what breaks out of order

1. **Relay first** (`deploy.sh --relay`): the new verifier accepts tokens with no `kind`, with `open` and
   with `protected`. This restarts the relay and drains live sessions (`MJOLNIR_RELAY_DRAIN_SECONDS`,
   default 30), which is an owner gate. Today's tokens carry no `kind`, so clients reconnect normally.
2. **Gateway** (`.13`): ships with the same verifier from its first release.
3. **Controller**: accepts `kind`, writes the room record, and puts `kind: "open"` only in open tokens.
   Protected tokens stay claim-free, so they verify on old and new relays alike. Open issuance stays off
   until a switch is set.
4. **Switch**: `MJOLNIR_RELAY_OPEN_ROOMS=true` in `/etc/mjolnir-relay/relay.env`, set only after step 1 is
   confirmed on that host. The mint reads that file on every call.

Out of order:
- **Open issued before the relay is updated:** every open token is refused by the old relay
  (`refused: unauthorized`, spike C1). Open rooms cannot connect; protected rooms are unaffected. It fails
  closed and loudly.
- **The mint putting `kind: "protected"` into protected tokens:** that would break every call on an old
  relay. Absence is therefore protected, and the mint never emits the explicit value.
- **Relay rolled back with open tokens live:** those sessions are refused on reconnect. Turn the switch off
  and wait out the ceiling first.
- **Controller rolled back:** the old mint ignores `kind`. It issues a protected token for a room recorded
  open, without consulting or deleting the store. A client that asked for open must treat a response without
  `kind: "open"` as a failure. Turn the switch off before a rollback; the records survive for roll-forward.
