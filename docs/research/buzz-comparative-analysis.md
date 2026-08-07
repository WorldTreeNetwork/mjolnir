# Buzz (Block/Dorsey) — Capability Report & Comparative Analysis vs. Mjolnir + IdentiKey + recrypt

**Date:** 2026-08-06
**Author:** research pass (search-router fan-out: Brave/Exa/Tavily/Serper + Firecrawl on primary sources)
**Primary sources:** `github.com/block/buzz` — `README.md`, `VISION.md`, `VISION_SOVEREIGN.md`,
`VISION_REMOTE_AGENTS.md`, `VISION_MESH.md`, `ARCHITECTURE.md`, `NOSTR.md`.
**Secondary:** TechCrunch 2026-07-21, The Verge 2026-07-21, Block Engineering blog, Decrypt, explainx.ai (HN pushback).

---

## 1. What it is, factually

Block (Jack Dorsey's company) released **Buzz** on **2026-07-21**, Apache-2.0, at
`github.com/block/buzz`. Shipped version at launch was ~0.4.21. Desktop builds at `buzz.xyz`
(Tauri 2 + React 19); relay is a Rust/Axum Cargo workspace.

Dorsey's framing on X: *"model-agnostic, decentralized, self-sovereign, and open source… built to
reduce our dependency on slack and github."*

The accurate one-line description, from their own README: **a self-hostable Nostr relay with a chat,
git, workflow, and agent client on top of it.** Every action — message, reaction, workflow step,
review approval, git patch, canvas edit, huddle join — is a signed Nostr event (NIP-01: secp256k1
pubkey, Schnorr sig, integer `kind`) in one Postgres-backed log.

Block is dogfooding it internally as their Slack/GitHub replacement.

---

## 2. Architecture in one screen

```
Clients:  Buzz desktop (Tauri/React) │ AI agents via buzz-acp (ACP↔MCP) │ buzz-cli / scripts
             │ WebSocket                    │ WS + REST                      │ WS + REST
             ▼                              ▼                                ▼
          ┌──────────────────────────────────────────────────────────────────────┐
          │                            buzz-relay                                │
          │  NIP-01 event store · NIP-42/98 Schnorr auth · channel/DM/media/     │
          │  workflow/git REST · hash-chain audit log · Opus voice relay         │
          └───────┬──────────────────────┬───────────────────────┬───────────────┘
             Postgres 17            Redis pub/sub            S3/MinIO
          (events + FTS,             (<50ms p99             (Blossom
           monthly partitions)        fan-out)               BUD-01/02)
```

Crates: `buzz-core` (zero-I/O types + kind registry) · `buzz-relay` · `buzz-db` · `buzz-auth` ·
`buzz-pubsub` · `buzz-search` · `buzz-audit` · `buzz-cli` · `buzz-acp` · `buzz-agent` ·
`buzz-dev-mcp` · `buzz-workflow` · `buzz-persona` · `git-sign-nostr` / `git-credential-nostr` ·
`buzz-media` · `buzz-sdk`.

**The one dispatch switch is the `kind` integer.** Standard Nostr kinds 0–9999, Buzz custom kinds
40000–49999, ephemeral 20000–29999. ~127 kinds defined; `ALL_KINDS` has 80 stored entries.
Selected: `9` stream message (NIP-29 group chat), `40100` canvas, `43001` agent job request,
`45001/45003` forum post/comment, `46001–46012` workflow execution, `20001` presence heartbeat,
`13534` membership roster, `39000/39001/39002` group metadata/admins/members (relay-signed).
New feature = new integer = zero breaking changes to existing clients. That is the actual
extensibility thesis, and it's a good one.

Stated scale target: 10K humans + 50K agents, ~600K events/day, Postgres FTS, hash-chain
tamper-evident audit.

---

## 3. What it actually gives you

| Capability | State | What it means |
|---|---|---|
| **Chat: Stream / Forum / DMs** | ✅ ships | Slack-like fast channels, Discourse-like async threads, group DMs ≤9. One event log, three lenses. Zero-notification default. |
| **Agents as members, not bots** | ✅ ships | An agent gets its own secp256k1 keypair, its own NIP-05 handle (`alice@example.com`), its own channel memberships, its own audit trail. You add it to a channel like a person. Auth via NIP-98. Bot role flag on membership. |
| **MCP server, full surface** | ✅ ships | Agents drive the *entire* platform — channels, canvases, workflows, huddles, repos — through MCP tools. Not a chat-reply bot: a workspace operator. |
| **ACP harness** | ✅ ships | `buzz-acp` bridges Goose, Codex, and Claude Code into the relay. Model-agnostic in the real sense. |
| **`buzz-cli`** | ✅ ships | JSON-in/JSON-out agent-first CLI, two-tier auth (NIP-98 keypair → dev pubkey). Canonical interface for repo/upload/canvas ops. |
| **Git hosting** | ✅ ships | Relay hosts repos. Standard smart-HTTP `git clone`/`git push`. Your npub signs pushes (`git-sign-nostr`, `git-credential-nostr`). NIP-34 patch/repo-announce/status events. |
| **Branch = channel** | ✅ (forge vision) | Create a feature branch → Buzz creates a channel. CI results, review comments, merge decision all land there. On merge the channel archives into the permanent record of *why* the code exists. |
| **YAML workflows** | ✅ ships (⚠️ gap) | Channel-scoped automation, message/reaction/schedule/webhook triggers, every step traced. **Approval gates are broken** — schema/REST/MCP/UI exist, but the executor doesn't persist the approval token, so a `request_approval` step marks the run Failed (their bug WF-08). |
| **Canvases** | ✅ ships | One shared doc per channel, read/write from desktop or MCP. |
| **Media** | ✅ ships | Blossom protocol (BUD-01/02) on S3/MinIO, server-side thumbnails, frame-anchored video comments. |
| **Huddles** | ✅ ships | WebSocket Opus voice relay built into `buzz-relay` — no external SFU. Agents join the same audio relay (BYO STT/TTS). Lifecycle flows as Nostr events. |
| **Search** | ✅ ships | Postgres FTS, permission-aware. One query returns the bug report + channel discussion + patches + CI results + design doc. |
| **Audit** | ✅ ships | Hash-chain, tamper-evident. Soft-deleted events remain. eDiscovery works on everything (because nothing is E2E encrypted — see §5). |
| **Buzz Mesh** | ✅ ships | Community members pool idle GPUs; `mesh-llm` over **iroh**; agents consume via a local OpenAI-compatible endpoint. Large models split across several machines. Relay membership *is* the mesh admission gate. |
| **Agent personas & teams** | ✅ ships | Persona = model + system prompt. Team = named group of personas. |
| **Remote agents** | ✅ **shipped** (see §9) | Deploy an agent onto remote substrate via a swappable **provider binary** (`buzz-backend-<id>`); Kubernetes is the reference binding. Governed by a 1,780-line formal spec at `docs/remote-agents.md`, `protocol_version: 1`. |
| **Multi-tenant communities** | 🚧 spec | URL is the tenant boundary. Isolation mechanized in **TLA+** and authorization in **Tamarin**, mutation-tested. (Notably rigorous.) |
| **Mobile** | 🚧 | Flutter, in development. |

---

## 4. The affordances that are genuinely new

Strip the marketing and four things here did not exist in this combination before:

**4.1 — Agent identity as a first-class principal, scoped by key rather than by permission flag.**
Every prior "AI in your workspace" product models the agent as an *integration* acting with a
human's or an app's credentials. Buzz gives the agent its own keypair, its own membership rows, its
own signed history, and its own audit chain. The consequence is not cosmetic: you scope an agent the
way you scope a teammate (channel membership), you can read exactly what it did and prove it, and
its reputation accrues to a portable identifier rather than to a vendor account. This is the single
most important idea in the release.

**4.2 — One event log across chat, code, CI, review, and automation.**
Because a message, a git patch (NIP-34), a workflow step, and a review approval are all the same
shape — a signed event with a kind integer — they land in one store with one search index and one
permission model. "Search the conversation, the patch, the workflow run, and the approval in one
query" is a real affordance that the Slack+GitHub+CI+Notion stack structurally cannot offer, because
those systems federate identity by OAuth and federate nothing else.

**4.3 — The approval as cryptographic artifact.**
A code review approval is a Schnorr-signed event. Not "GitHub's database says Alice clicked
approve" but "here is a signature over this decision that verifies against Alice's key without
asking GitHub anything." Same for merges and releases. That's a supply-chain provenance primitive
that fell out of the identity model for free.

**4.4 — Membership as a universal capability gate.**
The most elegant structural move in the whole design: the *same* membership decision gates your
channels, your repos, your search index, **and now your compute** (Buzz Mesh). One trust decision,
no separate ACL to maintain per subsystem. When membership ends, the path back to all of it ends.

Secondary but notable: **remote agents with no control plane.** Their axiom is that after deploy,
the desktop retains *no substrate control channel* — status, steering, and shutdown all flow over
the relay, and the agent bounds its own lifetime with an inactivity timer and exits cleanly. "A
management plane you never build is a management plane you never have to port." That's genuinely
good design taste, and it's directly relevant to us (§7.1).

---

## 5. What it is *not* — the honest limits

This matters for the comparison, so be precise rather than dismissive.

**5.1 — It is not peer-to-peer, and "decentralized" is doing heavy lifting.**
Corroborated by HN pushback and consistent with Block's own docs: **Buzz has no inter-relay event
exchange, no gossip layer, and no replication between relays.** It speaks the Nostr *wire format*;
it does not participate in the Nostr *network* for workspace data. Each relay is an island. What is
decentralized is the *choice of who hosts* (self-host or pick an operator) and the *portability of
identity*. What is centralized is every relay, individually and completely.

**5.2 — The relay is a trusted authority, not a dumb pipe.**
`VISION.md` says it outright: *"The relay enforces all access control."* Beyond that, the relay
**signs events itself** — group metadata (39000), admin lists (39001), member lists (39002),
membership notifications (44100/44101), the roster (13534). Membership is a row in a `relay_members`
table. The relay owner is bootstrapped from a `RELAY_OWNER_PUBKEY` env var and cannot be removed by
protocol action. So the trust model is: *your key proves who you are; the relay operator decides
what you may see and can author state on your behalf.* That is a fine model for a company workspace.
It is not self-sovereign in the sense we use the word.

**5.3 — No end-to-end encryption. At all. On purpose.**
`VISION.md`: *"One model. TLS in transit. At-rest encryption delegated to the storage layer (e.g.,
Postgres TDE, volume encryption). Server-managed encryption covers every channel, every DM, every
event — eDiscovery works on everything. End-to-end encryption (NIP-44) is a future consideration for
DMs."* The relay operator can read every DM. This is a deliberate enterprise-compliance choice, and
it is the largest single divergence from the IdentiKey thesis. **It is also the clearest place where
recrypt is a drop-in advantage rather than a competing idea (§7.3).**

**5.4 — Remote agents hand over the private key.**
Their own honest-costs section: deploying remotely means trusting the provider binary and the target
substrate with the agent's identity key. On Kubernetes it rests as a Secret — *"anyone the cluster
trusts to read secrets in that namespace can read it."* They narrow blast radius (immutable
per-attempt secrets, no service-account token, digest-pinned images) rather than claiming isolation
they don't have. **This is precisely the gap a microVM substrate closes.**

**5.5 — Self-reaping has a hole they acknowledge.** The inactivity timer runs inside the body it
exists to end; a wedged body can't finish itself, and the desktop won't do it. Their answer is
"namespace TTL policy is the backstop." That is a substrate problem they've punted to the substrate.

**5.6 — Workflow approval gates don't work yet** (WF-08), and mobile is incomplete.

---

## 6. Comparative analysis: Buzz vs. our stack

### 6.1 Where the two stacks actually sit

They are **not competitors**. Buzz is a *collaboration and coordination plane*. Mjolnir is an
*execution and isolation plane*. They meet at exactly one seam — where an agent needs a body — and
that seam is the opportunity.

```
        ┌─────────────────────────────────────────────┐
 BUZZ   │ workspace: channels, forum, git, workflows  │
        │ identity: secp256k1 npub, NIP-05, NIP-42/98 │
        │ substrate provider ──────┐   (K8s first)    │
        └──────────────────────────┼──────────────────┘
                                   │  ← THE SEAM
        ┌──────────────────────────┼──────────────────┐
MJOLNIR │ microVM spawn/exec/snapshot/dormant/wake    │
        │ BTRFS CoW · vsock · Iroh QUIC · virtio-fs   │
        │ Forge host reconciler · Forgejo CI runner   │
        │ Sites (content-addressed, signed manifests) │
        └─────────────────────────────────────────────┘
        ┌─────────────────────────────────────────────┐
IDENTI  │ ikey wallet (Argon2id + XChaCha20, Gordian) │
 KEY    │ enclave auth (Secure Enclave/TPM), Ed25519  │
        │ + ML-DSA-87 post-quantum                    │
        └─────────────────────────────────────────────┘
        ┌─────────────────────────────────────────────┐
RECRYPT │ PQ proxy recryption (OpenFHE BFV + liboqs)  │
        │ KEM-DEM, XChaCha20 + Bao, atomic revocation │
        └─────────────────────────────────────────────┘
```

### 6.2 Capability-by-capability

| Affordance | Buzz | Our stack today | Read |
|---|---|---|---|
| Cryptographic identity for agents/humans | secp256k1 npub, NIP-05, NIP-42/98 | ikey wallet: Ed25519 **+ ML-DSA-87 PQ**, hardware-enclave-backed (Secure Enclave/TPM 2.0), Gordian Envelope, audience-bound challenges, **no relying-party server required** | **We are ahead.** Theirs is software keys in env vars (`BUZZ_PRIVATE_KEY`); ours is enclave-resident and post-quantum. |
| Identity portable across hosts | ✅ npub travels; community state does not | ✅ same property; wallet is a file you own | Parity in principle. They have the client UX; we have the key hygiene. |
| Isolation of running agent | ❌ container/K8s Secret; "anyone who can read secrets in the namespace" | ✅ **microVM** — hardware KVM boundary, per-VM Iroh keypair at `/etc/mjolnir/iroh.key`, per-VM rootfs subvolume | **We are substantially ahead.** This is our sharpest edge. |
| Agent pause/resume with state intact | Relay keeps identity+history; **body state is mortal** ("files, checkouts, half-finished working trees — gone") | ✅ **BTRFS snapshot + DormantRegistry**: `handle_done` → snapshot → stop hypervisor → auto-restore on next message, full FS state intact | **We are ahead, and it's not close.** They explicitly concede this as an honest cost. We solved it at the substrate. |
| Self-reaping / no orphans | Inactivity timer inside the body; wedged body needs substrate TTL backstop | ✅ `Mjolnir.Cleanup` sweeps orphan hypervisors, stale TAPs, sockets on startup; `mj doctor --fix`; health monitor | **We are the backstop they're asking for.** |
| Compute pooling | Buzz Mesh: `mesh-llm` **over iroh**, gated by relay membership | Mjolnir mesh vision: Iroh overlay, BEAM distribution (libcluster + Syn), BTRFS send/receive replication — **vision, not shipped** | They shipped GPU pooling; we have a deeper multi-node design that isn't built. Both use Iroh — genuine convergent evolution. |
| Content addressing / publishing | Blossom BUD-01/02 on S3/MinIO; repo-as-website via content negotiation | ✅ **IdentiKey Sites**: Bao/BLAKE3-verified chunks on BTRFS, Gordian-enveloped signed manifests, signed HEAD pointer, **OpenTimestamps**, multi-sig, three serving modes | **We are ahead on verifiability.** They have blob storage; we have a three-axis independently-verifiable publish chain. |
| Encryption at rest / E2E | ❌ none — server-managed, operator reads all DMs | ✅ recrypt: PQ proxy recryption, KEM-DEM, **atomic revocation without re-encrypting**, capability-gated and group modes | **We are ahead by an entire category.** Their #1 admitted gap is our shipped product. |
| Chat / forum / huddles / canvases | ✅ shipped, polished, dogfooded at Block | ❌ nothing | **They are ahead by an entire category.** We have no collaboration surface. |
| Git hosting + review as signed events | ✅ smart HTTP, npub-signed pushes, NIP-34 | Forgejo (conventional) + `mjolnir sites publish` | They are ahead. Forgejo is a normal forge with normal accounts. |
| CI | Agent-as-CI-member watching branch channels | ✅ **Forgejo runner with VM backend** — jobs execute in real microVMs, not Docker | We're ahead on CI *isolation*; they're ahead on CI *integration with the conversation*. |
| Agent tool surface | MCP full surface + `buzz-cli` + ACP harness | ✅ `Mjolnir.MCP.Server`, 13 tools (`spawn_vm`, `exec`, `stop_vm`, snapshots, `deliver_message`, `get_connection_ticket`…) | Complementary — theirs is workspace verbs, ours is compute verbs. They compose. |
| Host config management | ❌ none | ✅ **Forge** three-way reconciler with ownership tracking, TLA+-free but adopt/ignore/prune first-class, audit JSONL, SSE | We're ahead; they have no equivalent. |
| Formal verification | ✅ TLA+ (isolation) + Tamarin (authz), mutation-tested | ❌ none | **They are ahead.** Worth stealing the practice for our multi-tenant Sites boundary. |

### 6.3 The exit test, applied to Buzz

Duke's test: *can a user leave with their private keys and their data intact, and stop paying,
without permission?*

- **Keys:** ✅ Pass. Your npub is yours; nothing can revoke it; it works on any relay.
- **Data:** ⚠️ **Conditional pass, and only if you self-host.** Community state is relay-local, there
  is no inter-relay replication, and the relay operator enforces all access. If you're a member of
  someone else's community, your history lives in *their* Postgres, and you have no protocol-level
  right to a copy. `VISION_SOVEREIGN.md` says "identity is portable even when the hosting isn't" —
  that is an honest admission that **data exit is not guaranteed**.
- **Stop paying:** ✅ Pass for self-hosters. Apache-2.0, whole stack, no license server.
- **Confidentiality on exit:** ❌ **Fail.** No E2EE means the operator has always had plaintext of
  everything, including DMs. Leaving doesn't un-read it.

**Verdict: Buzz passes the exit test for a self-hoster and fails it for a tenant.** That is exactly
the gap our stack was designed to close — and it's a defensible, non-hand-wavy differentiator we can
state publicly without disparaging their work, because *they say it themselves in their own docs.*

---

## 7. What we should do about it

Ranked by leverage-to-effort.

### 7.1 ⭐ Build a Mjolnir remote-agent provider for Buzz *(highest leverage)*

> **Corrected 2026-08-06 — see §9.** This section originally said the provider contract was "in
> review." It is not: it is published, versioned, and already has third-party implementations.
> The correction makes the recommendation stronger, not weaker.

Their remote-agent contract is **published, Kubernetes-referenced, and provider-based by design** —
a small swappable binary the desktop discovers and interrogates. The provider contract "never
mentions containers." They explicitly name the future substrates: *"a cluster today; a VM, a PaaS,
or something serverless-shaped tomorrow."*

Read their five contract obligations against what Mjolnir already does:

| Provider must… | Mjolnir |
|---|---|
| preserve the agent's identity and fail closed with its key | Per-VM Iroh keypair at `/etc/mjolnir/iroh.key`, preserved across checkpoint/restore when requested, deleted from clones by default. `Mjolnir.SecretStore` / `SecretEscrow` for injection. |
| converge to a single live instance no matter how deploys race | `Mjolnir.VMRegistry` — `{:via, Registry, {VMRegistry, vm_id}}` gives single-instance semantics by construction |
| let presence describe conversational availability, not substrate health | `Mjolnir.EventBus` lifecycle events; guest agent ping |
| bound the instance's lifetime | **DormantRegistry** — better than bounded: `handle_done` snapshots and parks, wakes on `deliver_message` |
| keep secrets out of configuration | `SecretStore` + `SecretEscrow` + vsock-injected identity, never in a readable Secret object |

And the two costs they list as unavoidable — *"handing over the key is a decision… anyone the
cluster trusts to read secrets in that namespace can read it"* and *"the body's state is mortal…
files, checkouts, half-finished working trees — gone"* — **are both artifacts of choosing containers
as the substrate.** A microVM with a hardware isolation boundary and instant CoW snapshots doesn't
have either problem.

The pitch writes itself: *"Same provider contract. Hardware isolation instead of a namespace Secret.
And the body's state isn't mortal — snapshot it, park it, wake it on the next mention."*

This is the single best distribution opportunity in the release. It puts Mjolnir under an
Apache-2.0 project Block is dogfooding, at exactly the layer we're strongest, filling two gaps
they've published as known weaknesses. Cost is bounded: implement one provider binary against a
documented contract plus their conformance suite.

**Action:** ✅ **done — see `docs/plans/initiatives/buzz-provider.md` (Mjolnir-side work) and the
`buzz-backend-mjolnir` repo (the provider itself).**

### 7.2 Run Buzz on Mjolnir, self-hosted, and dogfood it

Buzz ships a Docker Compose bundle (Postgres, Redis, MinIO, optional Caddy/TLS). Mjolnir already
runs Postgres as a supervised sidecar, has a gateway with cert management and domain routing
(`mj domain set`), and spawns isolated VMs. A Buzz relay per community, in a Mjolnir microVM, behind
the Mjolnir gateway, is a natural fit — and it makes their multi-tenant isolation story *stronger*
(hardware boundary per community instead of row-scoping in shared Postgres).

This is also the cheapest way to evaluate the thing honestly rather than from docs.

### 7.3 ⭐ Offer recrypt as the encryption layer Buzz doesn't have

Their gap statement is explicit and unhedged: *"End-to-end encryption (NIP-44) is a future
consideration for DMs."* Meanwhile they need eDiscovery, which is why they punted.

**Recrypt resolves that tension rather than trading it off** — and this is the argument to lead
with. Proxy recryption means the relay holds ciphertext and per-viewer recryption keys, recrypts the
wrapped KEM key on each read, never touches the DEM bulk ciphertext, and **revocation is atomic**.
Compliance/eDiscovery becomes a *capability grant to an auditor npub* — a signed, revocable,
auditable act — instead of standing plaintext access for whoever runs the box. That is strictly
better on both axes, which is a rare thing to be able to say.

Add ML-DSA-87 and the whole thing is post-quantum, which secp256k1 Schnorr is not.

The IdentiKey Sites design already proves the unification: "public static site" and "encrypted group
document" are the same system differing only in **key disclosure policy**. Buzz channels are the
same shape — a public channel and a private DM differ only in who gets keys.

### 7.4 Steal four ideas outright

1. **Kind-integer extensibility.** "New feature = new integer = zero breaking changes" is a
   genuinely superior versioning strategy to what most event systems do. Mjolnir's `EventBus`,
   Forge's `Events`, and the Sites manifest format could all adopt a registered-kind discipline.
2. **Branch = channel = permanent record.** Applies directly to our Forgejo runner: a CI job could
   own a durable record whose archive explains why the code exists. We already have the syslog
   transport and EventBus to feed it.
3. **"The relay is the only tether."** The no-control-plane axiom is excellent design taste and
   maps cleanly onto Mjolnir: after spawn, VM lifecycle control should flow through one channel
   (vsock/Iroh), not accumulate side channels. Worth auditing our current surface against it.
4. **TLA+ / Tamarin for the tenant boundary.** They mechanized multi-tenant isolation and
   authorization and mutation-tested the guarantees. If IdentiKey Sites ever serves multiple
   IdentiKeys from one host, that's the bar — and "proven, not asserted" is a marketing asset as
   much as an engineering one.

### 7.5 Do *not* rebuild Buzz

We have no collaboration surface and building one is a multi-year commitment against a well-funded,
already-dogfooded, Apache-2.0 incumbent. The differentiators we hold — hardware isolation,
checkpointable computation, post-quantum enclave identity, proxy recryption, verifiable publishing —
are all *below* the collaboration layer. Compete on the substrate; integrate at the surface.

---

## 8. The one-paragraph summary

Buzz is a very good Nostr-flavored workspace: chat + forum + git + CI + workflows + voice in one
signed event log, where AI agents are first-class members with their own keys, their own memberships,
and their own audit trails. Its genuinely new affordances are agent-identity-as-principal,
one-log-across-all-work-artifacts, the approval-as-signed-artifact, and membership-as-universal-gate
(now including compute, via Buzz Mesh over iroh). Its honest limits are that it isn't peer-to-peer
(no inter-relay replication), the relay is a trusted authority that signs state on your behalf,
there is **no end-to-end encryption by design**, and remote agents hand their private key to a
Kubernetes Secret while their filesystem state dies with the pod. Those last two limits are the two
things our stack is *best* at. The move is not to compete: it's to become the substrate their remote
agents run on (microVM isolation + snapshot/dormant/wake solves both their published costs) and the
encryption layer their DMs don't have (recrypt makes E2EE and eDiscovery compatible instead of
opposed). Compete on the substrate, integrate at the surface.

---

## 9. Corrections and resolved questions (deeper read, 2026-08-06)

Two of the original open questions resolved, and both change the plan **in favor of moving sooner**.

**9.1 — The provider contract is published, not in review.** `VISION.md`'s 📋 status lags the code.
`docs/remote-agents.md` is a **1,780-line formal specification** — *"Remote Agents and Their
Management"* — at `protocol_version: 1`, with five RFC-2119 invariants (**I1** identity fail-closed,
**I2** no secrets in configuration, **I3** presence is the status, **I4** at most one live instance
per key per scope, **I5** intentional termination is final), a three-layer conformance model
(**[L1]** launcher / **[L2]** provider / **[L3]** binding), a reference binding
`buzz-backend-kubernetes`, and a §Known Defects section listing 8 open entries. Third parties are
already shipping `buzz-backend-*` binaries — [issue #4730](https://github.com/block/buzz/issues/4730)
reproduces a bug against "a third-party backend provider implementing the documented provider
protocol."

The contract is also **much smaller than assumed** — two JSON ops over stdio, and no `undeploy` in
v1:

```
info:   {"op":"info","request_id":…}                            → {ok,name,version,protocol_version,description,config_schema}   10s
deploy: {"op":"deploy","request_id":…,"agent":{…},"provider_config":{…}} → {ok,agent_id}                                        600s
```

**9.2 — The owner-attestation claim is confirmed.** The `deploy` payload carries an `auth_tag` field,
documented as a **NIP-OA owner attestation**. So the secondary reporting that agent keys are tied to
a human owner via a second signature is accurate; §5 of this report flagged it as unverified on the
strength of `VISION.md`/`AGENTS.md`/`NOSTR.md` alone.

**9.3 — Two spec passages that materially help us.**

- **§Launchers:** *"The desktop is therefore one launcher among many, and the provider protocol is
  the desktop's door to substrates, not the only door."* A bash script, a systemd unit, or a CI job
  are all blessed launchers owing only the [L1] obligations. Mjolnir can therefore deploy Buzz
  agents **without going through their desktop at all** — two integration surfaces, and we can ship
  the deeper one on our own schedule.
- **I5 boundary (a):** the wedged-body problem is explicitly punted to the substrate ("a
  namespace-level TTL policy… out of scope"). Mjolnir's out-of-guest health probe is a strictly
  better answer than a TTL, and is offered upstream as such.

### Still open

1. Does `buzz-acp` assume a POSIX-local agent process, or can it target a remote body cleanly?
2. Does Buzz Mesh's iroh usage conflict or compose with Mjolnir's iroh endpoints on the same host?
3. Licensing: Buzz is Apache-2.0; recrypt is multi-licensed (AGPL / Apache / BSD-2-Patent /
   commercial). Which recrypt license path allows a Buzz-side integration?
4. Buzz's relay runs permission-aware **Postgres FTS over message content**, which collides head-on
   with encrypting message bodies. This is why the encryption wedge is **Blossom blobs first**, not
   DMs — see the initiative doc.
