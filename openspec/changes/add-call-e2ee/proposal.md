# add-call-e2ee

> **PENDING** — contract and spikes only. Goes to a Fable advise before any code.

Bead: `mjolnir-rurh.9` (call-media-e2ee). Parent: `mjolnir-rurh` (platform-calls). Blocks `mjolnir-rurh.5` (browser-call-client). Depends on `mjolnir-rurh.2` (edge-relay, folded). Rigor: architecture (cryptography, protocol).

## Why

The edge relay terminates QUIC. It can read every media frame, every catalog and every track name in a room (`openspec/specs/relay-room-auth/spec.md`). A call platform whose operator can watch the calls does not pass the exit test in spirit: the substrate (what people say and show) must be theirs, not ours.

moq ships an end-to-end profile for this at our pin: Rust `moq-e2ee` and `@moq/e2ee` at `4a6f52248`, profile `moq-e2ee-01-wip` from `draft-lcurley-moq-e2ee`, AES-128-GCM under HKDF-SHA-256 keys derived from a 32-byte credential the application distributes. It is marked unpublished and experimental. iroh-live `747b1bd` does not use it.

## What

- Capability `call-e2ee` (new). In a relayed call, media, catalogs and track names are readable only by holders of the room's content credential. The relay and the host see the tenant path prefix, the participant label, an opaque segment, the publisher epoch, sizes and timing. They hold no content key.
- Two credentials stay separate. The **room token** (moq-auth JWT from `Mjolnir.Relay.Mint`) says who may connect and under which label. The **content credential** (`{profile, kid, secret}`, context derived from the room) says who may read. Mjolnir mints the first and never sees the second.
- A protected broadcast lives at `t/<owner>/<room>/<label>/<opaque>/<epoch>`, inside the room token's `publish: [<label>/**]` and `subscribe: [**]` unchanged. `<opaque>` is `credential.path(<label>)`. `<epoch>` is the publisher instance's UUIDv7.
- A browser guest gets the credential in the link's URL fragment. The page drops the fragment from history on load and never sends it anywhere.
- Removing a member is a new credential (next `kid`, new secret) given to the members who stay. Every remaining publisher ends its old broadcast and publishes under the new one on the same session. No session restarts.
- Native iroh-live publishers take part without a fork, through `Node::publish_with` and an in-process bridge.
- On by default in the shipped browser client (`mjolnir-rurh.5`). There is no plaintext fallback inside an encrypted room.

## Impact

- Capabilities: ADDED `call-e2ee`. `relay-room-auth` and `edge-relay` are not modified: the relay, the mint and the token claims stay exactly as they are. The relay needs no new code and no redeploy for this change.
- ADRs: draft `docs/decisions/0017-call-e2ee.md` (Proposed).
- Code that will land after advise: a call-crypto module in the browser client (`mjolnir-rurh.5`), a Rust helper for native publishers, the acceptance harness. None is in this change yet.
- Pins: moq `4a6f52248` for both `moq-e2ee` (git dependency, `publish = false` upstream) and `js/e2ee` (private package, consumed from source at that revision). A profile bump is a coordinated client upgrade, never a relay change (design D7).

## User journey & surfaces

No new UI in this change: the call page is `mjolnir-rurh.5`. What this change fixes for that page:

- The owner starts a call. Their client generates the credential locally (`crypto.getRandomValues`, 32 bytes) and builds the invite link: `https://<call page>/#v=1&p=moq-e2ee-01-wip&kid=<n>&k=<secret, base64url>&t=<room token>`. Mjolnir mints only the room token.
- A guest opens the link. The page reads the fragment, removes it with `history.replaceState`, joins with the token and reads with the credential. The secret stays in the client; only the room token reaches relay admission. The owner mints a separate participant token and invite per guest, so sharing a credential does not share a publish label.
- Working: participants see and hear each other; the relay forwards ciphertext. Empty: a link with no `k` joins nothing and says the link is incomplete; it does not fall back to plaintext. Failed: a wrong or old credential finds no broadcast it can open; the page says "this link's key is no longer valid" after a bounded wait. Off: there is no unencrypted room mode in the shipped client.
- Removing someone: the owner's client mints the next credential and re-shares the link to the people who stay. Their pages switch broadcasts on the open session.

## Out of scope

- Sender authentication between credential holders. Any holder can encrypt; the relay's `<label>/**` grant is what stops a holder publishing under someone else's label (draft: "Sender authenticity against another endpoint that also holds the secret is not a goal").
- Padding and traffic-analysis resistance. Sizes and timing stay visible, including Opus voice activity.
- Distributing the credential beyond a link: Coopbase over FOKS is its own change.
- Revoking a room token before `exp` (relay-room-auth Limits). A removed member keeps relay access, but not content access, until their token expires.
- Where the call page is served from and how its code is pinned (`mjolnir-rurh.5`). The trust consequence is stated in design D3.
- Publishers inside Mjolnir guests (agents publishing media). The snapshot rule they must follow is stated in design D8 and owed by the change that ships one.
