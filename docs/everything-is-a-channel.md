A pipe in linux - a channel, like in pi calculus.

Linux, everything is a file. in Mjolnir, everything is a channel. Named channel sends data and receives, across processes or network. Or within the program. Evented.

Typed channels: types determine what goes through the channel

This overlaps a lot with graph databases. NextGraph does a RDF-based ontology/schema, with CRDT synchronization built-in.

dApp - p2p source code, content-based addressing.

---

## What "typed channels" turns out to mean

> Added 2026-08-07. The one-line requirement above is load-bearing and vaguer
> than it looks. Working it out produced a longer answer than belongs in this
> file — see [`computational-fabric.md` §1.4](computational-fabric.md) for the
> formal treatment. This is the short version.

**A channel type is not a payload type.** "Types determine what goes through the
channel" reads as though a channel is a typed container — `Channel<T>` — and
admission is a subtype check on `T`. That is *one* of the two questions, and the
easier one:

- **Payload admission** — may this value pass this channel? Subtyping over
  records. Solvable with the machinery we already have.
- **Channel typing** — is this channel usable this way? A different question. A
  channel has two ends, a direction, an order of operations, and a lifetime.

The difference bites immediately. Channel subtyping is **directional**: the
receive capability is covariant in the carried type, the send capability is
contravariant, and holding both makes it invariant. So "is this channel
compatible with that one" has no answer until you say which end you are holding.
Records have no such property, which is why record-shaped thinking quietly fails
here.

**A channel is a protocol, not a slot.** Most real channels are not "carries a
`T`" but "send a request, then receive a response" — or a stream, or a
negotiation with branches. That is a *session type*, and it has structure:
sequencing, choice, recursion, and **duality** — the two endpoints must have
mirror-image types or the conversation deadlocks.

## Where a type system for this already half-exists

Dreamball's *action manifest* — an archiform declaring its operations as data,
for projection into CLI verbs, REST routes and MCP tools — is a session-type
declaration language that does not know it is one. Every action is the
degenerate one-round-trip session `!Inputs . ?Outputs . end`, and fields added
for entirely practical reasons map onto the calculus: `effects` are sends on
other channels, `requires` are the process's free names, `agentVisible` is scope
restriction, and `implementation: {wasm: <blake3>}` is the process body itself,
content-addressed — `P` in the `⟨P, σ, κ⟩` remote closure of §1.1.

The consequence for us: **don't invent channel types for Mjolnir separately.**
Extend that manifest, so a CLI verb and a Mjolnir channel are the same
declaration projected differently rather than two systems that rhyme.

## Not yet

The correspondence is promising and not ready to build on. The only archiform
that exists uses about 60% of the vocabulary it already has — four of its five
actions carry placeholder implementation fingerprints, and none declares
`effects` at all. Adding session constructors now means designing them against a
single imagined consumer.

Get a second real consumer onto the existing vocabulary first. Let the missing
constructors be discovered rather than specified.

---

The retry-safe host mailbox — named send as a filesystem spool, 0MQ
patterns composed *above* that primitive — is
[`philosophy/mailbox-as-spool.md`](philosophy/mailbox-as-spool.md). Not
built. Not an ADR.
