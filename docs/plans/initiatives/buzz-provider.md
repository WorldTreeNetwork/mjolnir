# Initiative: Buzz Provider & Hosted Buzz-on-Mjolnir

**Status:** Design (2026-08-06)
**Owner:** Duke
**Tracking:** `mjolnir-e70` (epic, 9 children)
**Related:**
- `docs/research/buzz-comparative-analysis.md` — the capability report this follows from
- `~/work/IdentiKey/buzz-backend-mjolnir` — the provider binary (Apache-2.0, separate repo)
- `docs/plans/initiatives/identikey-sites.md` — the chunk/manifest layer the encryption wedge reuses
- `docs/plans/initiatives/mjolnir-sovereignty-vision.md`

---

## 1. Thesis

Block open-sourced [Buzz](https://github.com/block/buzz) on 2026-07-21 (Apache-2.0) and it is
getting real attention. It is a Nostr-relay-backed workspace where AI agents are first-class members
with their own keypairs. Its remote-agent system deploys those agents onto a substrate through a
**swappable provider binary** governed by a published formal spec.

Two costs that spec names as honest and unavoidable are **properties of containers, not of remote
agents**:

1. *"On Kubernetes, that key rests as a Secret: anyone the cluster trusts to read secrets in that
   namespace can read it."*
2. *"The body's state is mortal. Files, checkouts, half-finished working trees — gone with the body
   **unless the substrate supplies persistence**."*

Mjolnir is a substrate with a hardware isolation boundary and instant CoW snapshots. It has neither
cost. That is the whole wedge, and it is defensible in public because Block wrote both sentences.

**Three deliverables, deliberately separated:**

| # | Deliverable | Model | Why |
|---|---|---|---|
| **A** | `buzz-backend-mjolnir` provider | **Free, OSS, loud** | Distribution. The ad, not the product. |
| **B** | Hosted Buzz-on-Mjolnir | **Paid** | Revenue, differentiated by the exit guarantee (§4) |
| **C** | recrypt encryption for Buzz | OSS + commercial | The gap Buzz has published and won't close |

Do **not** monetize A. It is the top of the funnel for B.

---

## 2. Scope decisions taken (and the ones rejected)

Recorded because each was actively considered and the reasoning matters more than the verdict.

### ✅ Do not touch the curve

Buzz is secp256k1/Schnorr because Nostr is. The provider receives `private_key_nsec` as an opaque
string and sets `BUZZ_PRIVATE_KEY`; **Mjolnir performs no curve arithmetic anywhere in this path.**

On the merits, the tribal version of this argument is also wrong: secp256k1-Schnorr and Ed25519 both
give ~128-bit classical security and **both fall equally to a CRQC**. Preferring Ed25519 buys zero
post-quantum security. Our real post-quantum story is **ML-DSA-87 as the wallet root** protecting
*custody* of the key — which is additive, ships now, and doesn't require Buzz to agree with us about
anything.

The move is **custody, not replacement**: hold the `nsec` as an assertion inside an IdentiKey wallet,
exactly as `recrypt` already attaches its PRE key material via the `WalletIdentity` trait and
preserved unknown assertions.

### ❌ No Nostr↔MQ bridge in phase 1

Tempting, and wrong for now. The provider needs **zero** Nostr — two JSON ops on stdio. The agent
inside the VM speaks Nostr to the relay, but that agent is `buzz-acp`, Block's binary, which we
merely execute.

A selector making Mjolnir's agent mailboxes speak Nostr — so a Mjolnir-native agent appears as a
member in a Buzz channel without their harness — is a genuine **phase 3** differentiator. It is not
a launch dependency, and building it now delays the thing that rides the wave.

### ❌ Encryption does not start with DMs

The relay runs **permission-aware Postgres FTS over message content**. Encrypt message bodies and
search dies. That collision is precisely why Block chose server-managed encryption, and we would hit
it head-on.

**Blossom media/attachments have no FTS dependency** — content-addressed blobs on S3/MinIO, which is
the same shape as IdentiKey Sites already (content-addressed chunks + signed manifest + key
disclosure policy as the only variable). Start there. See §5.

---

## 3. Mjolnir-side work

The provider binary lives in its own repo. This is what **this** repo owes it.

### 3.1 🔴 BLOCKING — VM metadata and generation counter (`mjolnir-oux`, extends `mjolnir-cm2`)

The spec's reconciliation loop (**I4**) requires three substrate primitives Mjolnir does not have.
This is the critical path for everything else.

| Spec requirement | Kubernetes mechanism | Mjolnir need |
|---|---|---|
| Select candidates by identity | label selector (truncated pubkey) | **VM metadata map**, queryable |
| Authenticate a candidate | full-pubkey annotation compare | same map, exact-match read |
| Prove *we* created it | `managed-by` marker + schema-version | same map |
| Fence a destructive write | UID + `resourceVersion` compare-and-delete | **monotonic generation counter per VM record** |
| "Started", not merely accepted | container `state.running` | guest-agent vsock ping — ✅ **exists** |

**The generation counter is not optional.** Without compare-and-delete fencing, the destructive rows
of the reconciliation loop (delete residue, fenced replace, snapshot GC) cannot be implemented
conformingly. The correct interim behavior is to **refuse them**, not to implement them racily — the
spec's own rule is that a provider which cannot positively identify an object as its own output does
not repair around it, it reports it.

So: **P1 of the provider ships with reconciliation degraded to create-or-no-op with no destructive
repair**, and says so in `info`'s description. That is a conforming subset, and it unblocks the demo
without lying.

- [ ] Extend the VM record with a metadata map (`String => String`), persisted in `StateStore`
- [ ] Add a monotonic `generation` to the VM record, bumped on every mutation
- [ ] API: filter `GET /vms` by metadata key/value
- [ ] API: conditional delete (`If-Match: <generation>`) → 409 on mismatch
- [ ] `mj` surface for the above (`mj list --filter`, at minimum for debugging)

### 3.2 The `@base/buzz-agent` rootfs (`mjolnir-cxz`)

- [ ] Base subvolume carrying `buzz-acp` plus the ACP agents (goose / codex / claude-code)
- [ ] Add to `just build-ci-image` alongside the existing CI rootfs recipe
- [ ] **Open:** which agents to bake in vs. fetch at boot — sizing vs. cold-start
- [ ] Guest must run the harness as the **signal-receiving process**, so harness exit terminates the
      VM (required by the [L3] realization of I5)

### 3.3 Secret injection path (`mjolnir-1pe`) — the I2 story, and our best one

Mostly exists; needs wiring and a test that pins the property.

- [ ] `deploy` payload → `Mjolnir.SecretStore` → vsock injection at guest boot → harness env
- [ ] **Test the negative:** assert the nsec appears in *no* host-side artifact — not the VM record,
      not the API response, not the logs, not the syslog stream
- [ ] Optional: IdentiKey wallet custody (`identikey-wallet` `WalletIdentity` assertion)

### 3.4 Graceful stop with harness drain (`mjolnir-a5t`) — I3 staleness

The relay's presence TTL is **180 seconds**. A hypervisor kill that races the harness drain converts
a clean stop into an abnormal one and burns the whole window — so this is a conformance-relevant
constant, not a tuning knob.

- [ ] Stop path: vsock shutdown signal → wait for harness drain → then stop hypervisor
- [ ] Grace window ≥ the harness's full graceful-shutdown path
- [ ] Force-kill only after grace, and **classify it as an abnormal death** (see §3.5)

### 3.5 Wedged-body reaping (`mjolnir-j5o`) — close the boundary the spec punts

I5 boundary (a): a process too wedged to run its own reaper cannot reap itself; the spec suggests "a
namespace-level TTL policy" and calls it out of scope.

Mjolnir already has the better answer — `Mjolnir.Health` probes the guest agent over vsock **from
outside the guest**, so a wedged VM is detectable and reapable without in-guest cooperation. A TTL
kills healthy long-lived agents (the `inactivity_seconds: 0` case the spec explicitly blesses) along
with wedged ones; a liveness probe kills only the wedged.

- [ ] Wire health-monitor reaping to Buzz-marked VMs
- [ ] ⚠️ **Classify a force-reap as an *abnormal* death, never intentional.** Getting this backwards
      corrupts the intent/accident distinction that makes indefinite agents safe under I5.
- [ ] Offer the substrate-neutral phrasing upstream for spec v2

### 3.6 Snapshot-resume (`mjolnir-rnc`) — the differentiator

- [ ] On stop: `btrfs subvolume snapshot` the agent rootfs, tagged with the agent pubkey + markers
- [ ] On create: clone from the snapshot if one exists, else from `@base/buzz-agent`
- [ ] Retention policy per agent pubkey; GC under the same marker+generation fence
- [ ] 🚨 **Do NOT wire `DormantRegistry` wake-on-message to relay traffic.** I5 forbids automatic
      revival of an intentional exit. Snapshot-resume is an optimization of the **create path under
      an owner-initiated Start** — never a second trigger. This is the single easiest way to make
      the provider non-conforming, and it would be tempting precisely because the machinery already
      exists.

---

## 4. Hosted Buzz-on-Mjolnir — and the exit guarantee (`mjolnir-80q`)

Buzz's own `VISION_SOVEREIGN.md` invites operators: *"let an operator host thousands on shared
infrastructure."* Their multi-tenant model row-scopes a shared Postgres. **Ours would be a microVM
per community** — a hardware boundary instead of a query predicate. That is a straightforwardly
better isolation story and it costs us nothing, because it is what Mjolnir does.

### The exit test problem, and why it's the product

Applying Duke's test to Buzz: keys pass (your npub is yours, portable, unrevocable). **Data does
not.** There is no inter-relay replication and no export path. A tenant leaves with their identity
and none of their history. That is rent.

If we host Buzz and change nothing, we inherit that failure. But we are uniquely able to fix it: a
community is a Postgres DB plus S3 blobs, and on Mjolnir that is a BTRFS subvolume we can snapshot
and `btrfs send`.

> **"The only Buzz host you can walk away from — your whole relay, as a file, whenever you want."**

Every other Buzz host will be on K8s + RDS and structurally cannot offer this. It is the exit test
converted into the differentiator, and it is defensible in public because Block documents the
limitation themselves.

- [ ] One microVM per community; gateway domain routing per tenant (`mj domain set` exists)
- [ ] **Egress on demand:** signed, complete community export — event log + blobs + manifest
- [ ] Verify a restore into a bare self-hosted Buzz relay, from the export alone, with no help
      from us. **Untested egress is not egress.**
- [ ] B2 backup path (per `b2-backup-infra` memory: direct rclone → Backblaze, bucket
      `mimir-backups`; Sites/VM data is **not** yet backed up — this initiative needs it to be)
- [ ] Billing

---

## 5. recrypt as the encryption layer (`mjolnir-800`)

Buzz's stated gap: *"End-to-end encryption (NIP-44) is a future consideration for DMs."* Meanwhile
they need eDiscovery, which is why they chose server-managed encryption.

**Recrypt dissolves the tradeoff rather than picking a side** — this is the argument to lead with.
Proxy recryption means the relay holds ciphertext plus per-viewer recryption keys, recrypts the
wrapped KEM key on each read, never touches the DEM bulk ciphertext, and **revocation is atomic**.
Compliance access becomes a *capability grant to an auditor npub* — signed, revocable, audited —
instead of standing plaintext for whoever runs the box. Strictly better on both axes.

**Sequencing (per §2): Blossom blobs first, message bodies later.**

- [ ] **Phase 1 — Blossom/media.** Content-addressed blobs, no FTS dependency, same shape as
      IdentiKey Sites' chunk+manifest layer. Demo: revoke a contractor's access to every attachment
      atomically, without re-encrypting anything.
- [ ] **Phase 2 — canvases.** Also outside the message FTS path.
- [ ] **Phase 3 — DMs/channels.** Requires answering encrypted search first. Do not promise this
      before there is a design.
- [ ] Resolve which recrypt license path permits an Apache-2.0-side integration

---

## 6. Upstream contributions — sequenced to arrive as a contributor

1. **Fix [block/buzz#4730](https://github.com/block/buzz/issues/4730)** (`mjolnir-ceo`) — provider-backed agents
   render a hardcoded `<PresenceDot status="online" />` gated only on `isActive`, so remote liveness
   derives from `backend_agent_id` rather than presence, violating their own **I3**. Diagnosed to
   file and line in the issue; small fix; exactly our code path. **Do this before announcing
   anything.**
2. `VISION_REMOTE_AGENTS.md` — separate *body state* from *agent state* in the resurrection framing.
3. `docs/remote-agents.md` v2 input — substrate-neutral deletion-mark rule, liveness-probe backstop
   instead of TTL, and `undeploy` (which matters more on metered VMs than on Completed pod objects).

---

## 7. Sequencing

```
NOW      #4730 fix upstream ──────────────────────────────┐ (credibility, days)
         mjolnir-cm2: VM metadata + generation  🔴 BLOCKING│
              │                                            │
P1       @base/buzz-agent  +  provider deploy happy path ◄─┘
              │            "agent boots in a VM, answers a mention in a channel"  ← the demo
P2–P3    reconciliation (I4) · graceful stop (I3) · lifetime (I5) · wedged-body reaping
              │            ← minimum publishable provider; announce here
P4       snapshot-resume   ← the reason anyone switches
P5       IdentiKey custody ← the reason we built it
         ────────────────────────────────────────────────
B        hosted Buzz-on-Mjolnir + egress guarantee (needs P1–P3, not P4)
C        recrypt for Blossom blobs (independent of A; can run in parallel)
```

**Announce at P3, not P1.** A provider that deploys but mishandles termination will be judged
against a spec that is public, precise, and unusually well written. The comparison is unforgiving
and the audience will actually read it.

## 8. Risks

| Risk | Mitigation |
|---|---|
| Spec churns (8 known defects, no `undeploy`, `launch` unemitted) | Surface is two ops; churn is cheap. Being early is how our VM constraints land in v2 instead of us adapting to someone else's. |
| `mjolnir-cm2` slips | P1 ships the degraded-but-conforming subset; demo doesn't need destructive repair |
| Buzz attention fades before we ship | A and B stand on their own merits; the substrate arguments outlive the news cycle |
| We accidentally violate I5 with `DormantRegistry` | Called out in §3.6; make it a review checklist item, not a comment |
| Hosting inherits Buzz's data-exit failure | §4 egress is a **launch requirement**, not a follow-on |
