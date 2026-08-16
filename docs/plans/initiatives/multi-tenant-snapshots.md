# Multi-Tenant Snapshots: Per-User Encrypted, Replicable VM State

**Status:** Design (2026-08-13)
**Owner:** Duke
**Epic:** `mjolnir-tenant` (see beads)
**Related:**
- `docs/plans/rbac-design.md` — Biscuit capability tokens (the sharing layer)
- `docs/plans/initramfs-verified-boot.md` — three-tier storage, four encryption layers
- `docs/encryption-and-security.md` — consolidated security architecture
- `docs/plans/initiatives/identikey-sites.md` — SecretStore keyspace, IdentiKey fingerprints
- `docs/plans/initiatives/mjolnir-sovereignty-vision.md` — cross-node replication vision
- `~/work/IdentiKey/recrypt/docs/architecture.md` — PRE / OpenFHE BFV

---

## 1. Executive summary

Today Mjolnir is single-tenant by construction: one flat `@snapshots/` namespace, ownership
enforced only at the HTTP layer, and one host. The goal is a fabric where **every VM and
snapshot belongs to an IdentiKey-rooted account, tenant state is encrypted such that the host
operator cannot read it, and a user's VM can be brought up on any host in the fleet.**

The surprise on surveying the tree is how much of this already exists. Ownership plumbing is
complete. Per-VM LUKS encryption ships in two modes, one of which (`:persistent`) already keeps
the passphrase off the host entirely. The capability-token design is written. What is missing is
mostly *structure* — a tenant-shaped storage layout, an identity binding between the OIDC subject
and the user's IdentiKey, and a replication/placement layer.

One security hole must be closed before multi-tenancy ships: **memory snapshots write plaintext
guest RAM to disk**, which for any LUKS-unlocked VM includes the dm-crypt key.

---

## 2. Implementation reality check (verified against the tree, 2026-08-13)

**Already true — do not rebuild these:**

| Capability | Where | Notes |
|---|---|---|
| `owner_id` end-to-end | `api/router.ex:277`, `vm.ex:1044`, `authz.ex` | Stamped from authenticated `sub` at spawn, persisted in `StateStore.spawn_config` |
| Owner-scoped authz | `policy/vm.ex`, `policy/snapshot.ex`, `api/authz.ex` | Owner-equality on resource actions; list endpoints filtered; localhost bypass is deliberate |
| Snapshot owner metadata | `btrfs.ex:create_snapshot/3` | `owner_id` written to the JSON sidecar |
| Legacy-snapshot denial | `policy/snapshot.ex:32` | `owner_id: nil` already denied to non-localhost users |
| Per-VM LUKS | `vm.ex:42-44`, `secret_escrow.ex` | Two modes, below |
| Escrow outside the snapshot boundary | `secret_escrow.ex` | Escrow dir lives outside `btrfs_root`, so `btrfs subvolume snapshot` never captures passphrases |
| IdentiKey Ed25519 + fingerprints | `sites/identikey.ex` | Blake3→base58 fingerprint, stable across persistence |
| IdentiKey-rooted keyspace | `secret_store.ex` | `(identikey_fp, key)` signed-envelope store. Signature verify STUBBED |
| Capability design | `docs/plans/rbac-design.md` | Biscuit, 3 phases, not implemented |

### The two existing secrets modes

- **`:managed`** — host generates a random passphrase, escrows it, re-injects on every boot and
  dormancy wake. Explicitly *not* zero-knowledge; the trade buys autonomous scale-to-zero.
  Snapshots carry only the ciphertext LUKS blob.
- **`:persistent`** — passphrase held by a **remote Iroh peer**; refuses dormancy. The host never
  holds the key.

`:persistent` is already 80% of "encrypted to the user's key." What it lacks is DEK *wrapping* to
an IdentiKey — it takes a passphrase from a peer rather than a key cryptographically bound to the
owner's identity.

### Drift: the LUKS volume is a loopback file, not a virtio-blk device

`initramfs-verified-boot.md` §Layer 3 specifies tier 3 as a **virtio-blk** device so dm-crypt
operates on a real block device with no loopback indirection. The shipped implementation is a
**loopback container on virtio-fs**: `/var/lib/mjolnir/secrets.luks` + `losetup`
(`guest_agent/src/secrets.rs:21`, `:519`).

At-rest confidentiality still holds — the host sees only ciphertext in the container file. But the
documented rationale for virtio-blk (avoiding virtiofsd's DAX-mapped shared memory region) is not
being honoured, and the doc should either be reconciled to the implementation or the implementation
moved to virtio-blk. Filed as its own bead; it is adjacent to this initiative, not blocking it.

One incidental benefit of the current shape, relied on in §5.4: because the LUKS container is a
loopback device and *not* the root filesystem, it can be `luksSuspend`ed without deadlocking the
guest.

**Not true yet:**

- `@snapshots/` is a flat global namespace (`btrfs.ex:111` hardcodes the path)
- `owner_id` is a Keycloak `sub`, with no binding to any IdentiKey fingerprint
- Memory snapshots (`memory_snapshot.ex:98`) write plaintext guest RAM to `@snapshots/<name>.mem/`
- No node identity, placement registry, or cross-host replication of any kind
- No off-box backup of `@snapshots`/`@base` at all (bead `mjolnir-qwp`)

---

## 3. The four gaps

### 3.1 Flat snapshot namespace

`Btrfs.create_snapshot/3` resolves to `<btrfs_root>/@snapshots/<name>` with no tenant component,
and fails with `{:snapshot_exists, name}` on collision. Three consequences under multi-tenancy:

1. **Collisions.** Two tenants naming a snapshot `base` conflict.
2. **Enumeration leak.** The collision error is *informative* — tenant B learns tenant A holds a
   snapshot by that name.
3. **Advisory-only isolation.** `owner_id` is a JSON field checked at the API layer. Anything
   bypassing the API — an ops script, a bug, `rclone`, a future replication job — sees one
   undifferentiated pile with no structural boundary.

### 3.2 OIDC subject ≠ IdentiKey fingerprint

`owner_id` is the Keycloak `sub`: an identifier **the server assigns**. An IdentiKey fingerprint
is derived from a key **the user holds**. Encryption-to-user-key requires the latter. These are
different namespaces with different trust roots, and nothing currently connects them.

### 3.3 Memory snapshots defeat the LUKS tier

`memory_snapshot.ex:98` writes Cloud Hypervisor's memory artifacts to
`@snapshots/<name>.mem/`. That is the full guest address space. For any VM that has unlocked its
LUKS volume, **the dm-crypt DEK is in that file in cleartext.**

The entire tier-3 design rests on the DEK existing only in guest RAM. A memory snapshot makes
guest RAM a host file — and any off-box replication of `.mem` directories exports the key
alongside the ciphertext it is supposed to protect. Today this is acceptable (single tenant,
trusted operator). Under multi-tenancy it is a silent, complete bypass.

### 3.4 No placement or node identity

`Reconcile` and `StateStore` are single-host. Nothing models "which host holds this snapshot,"
and nothing remaps VM identity (CID, TAP, IP, Iroh node key) on restore elsewhere.

---

## 4. The encryption boundary — the one real decision

**Do not encrypt whole snapshots to the user's key.** It is the intuitive reading of the
requirement and it is the wrong architecture. `initramfs-verified-boot.md` already worked this
out; restating it because it is the crux:

| Tier | Content | At rest | Rationale |
|---|---|---|---|
| 1 | Base OS (`@base/ubuntu-24.04`) | Plaintext, Blake3-verified + signed | Public data. Shared reflink across all tenants. |
| 2 | App / workdir on virtio-fs | Plaintext | CoW dedup, compression, cheap incrementals |
| 3 | `data.img` via virtio-blk | LUKS2 `aes-xts-plain64`, DEK never on host | Secrets, credentials, PII, tenant data |

Encrypting tier 1 is strictly negative:

- **Dedup and compression die.** Ciphertext is high-entropy. The 7.5 GB of shared base images
  becomes 7.5 GB *per tenant*.
- **Reflink cloning stops working** — the primitive that makes Mjolnir spawn fast.
- **It protects nothing.** The base OS is the same Ubuntu everyone else has. Its *integrity*
  matters; its *confidentiality* does not. A signed Blake3 manifest delivers integrity without
  touching the CoW economics.

So: **"encrypted to each user's key" means tier 3 grows to hold everything tenant-specific, and
its DEK is wrapped to the owner's IdentiKey.** Tiers 1 and 2 stay shared and verified.

### Why proxy re-encryption, not just a passphrase

`:persistent` requires the user's peer to be reachable at boot. That is correct for the highest
security tier but fatal for "bring my VM up on any host, now."

PRE (`initramfs-verified-boot.md` Layer 2, OpenFHE BFV in `recrypt`) resolves it: the DEK is
encrypted under the user's public key; at spawn the host applies a re-encryption key `rk(A→B)` to
transform it into something the **VM's ephemeral key** can decrypt. The host performs the
transform without ever seeing the plaintext DEK or either private key.

This is the difference between *"the user must be online to boot on node 3"* and *"the user
pre-authorized node 3."* It is what makes fleet-wide placement compatible with host-opaque
encryption.

---

## 5. Target architecture

### 5.1 Storage layout

```
<btrfs_root>/
├── @base/                          # shared, plaintext, Blake3-verified (unchanged)
│   └── ubuntu-24.04/
├── @tenants/
│   └── <identikey_fp58>/
│       ├── vms/<vm_uuid>/          # live rootfs subvolume
│       ├── snapshots/<name>/       # + <name>.json sidecar
│       │   └── <name>.mem/         # memory artifacts — see §5.4
│       └── data/<vm_uuid>.img      # LUKS2 blob, DEK wrapped to <identikey_fp>
└── @trash/                         # unchanged
```

The tenant prefix becomes a **parameter** of `Btrfs.create_snapshot/clone_from_snapshot`, not a
constant. This buys three things at once:

- **Namespace isolation** — no collisions, no enumeration
- **Quota** — `btrfs qgroup` applies naturally per tenant subtree
- **Replication unit** — send a tenant's tree, not the host's

### 5.2 Identity binding

At first login the user proves possession of their IdentiKey; the server records a signed
`sub → identikey_fp` binding in `SecretStore`.

Thereafter the two identifiers do different jobs:

- **`owner_id` (the `sub`) stays the authz key** — a cheap string compare in `policy/*.ex`, no
  crypto in the hot path. Nothing about §5.2 changes the existing policy modules.
- **`identikey_fp` is the encryption key** — every DEK-wrapping and storage-path decision keys off
  the fingerprint.

Open: authoritative resolution when they disagree (key rotation, account recovery). See §8.

### 5.3 Capability tokens

Owner-equality cannot express sharing. `rbac-design.md` Phase 1 (Biscuit, dual-mode with existing
JWT, non-breaking) is the unlock: root capability minted at spawn, attenuated client-side, verified
offline. Snapshot sharing becomes "hand someone an attenuated token," not "ask the operator."

### 5.4 Memory snapshots — suspend the volume, don't hide the key

The instinct is to find a region of RAM the snapshot won't capture. **There isn't one, and there
can't be**, for a reason worth stating plainly: a memory snapshot exists to reproduce the guest
exactly. Any location the guest can reach at thaw time is by definition captured; any location not
captured is unreachable at thaw. The options that look promising all fail:

| Approach | Why it fails |
|---|---|
| Key in CPU/debug registers (TRESOR-style) | Cloud Hypervisor saves **vCPU state** to `state.json` — that is what makes restore work. Registers are captured. Defeats cold-boot attacks, not hypervisor snapshots. |
| Exclude a CH memory zone from the snapshot | Requires patching CH, *and* the guest cannot confine a dm-crypt key to one zone — the key is copied into the crypto tfm, scatterlists, and slab. |
| Guest kernel keyring | Still ordinary kernel RAM. |
| AMD SEV-SNP / Intel TDX | The real hardware answer — host-visible memory is ciphertext. But snapshot/restore under SNP requires a PSP-mediated migration agent; CH support is thin-to-absent. Track it; don't build on it. |

**The workable answer inverts the problem: don't keep the key out of the snapshot — make sure no
key exists at the moment of capture.**

`cryptsetup luksSuspend` suspends the dm device *and wipes the volume key from kernel memory*
(it exists for exactly this reason: suspend-to-disk). So:

```
freeze:  fsfreeze -f /secrets
         cryptsetup luksSuspend mjolnir-secrets   # volume key wiped from kernel RAM
         CH vm.pause + capture RAM                # captured RAM holds no usable key
thaw:    CH vm.resume
         inject_secrets over vsock                # EXISTING path — vm.ex:2422
         cryptsetup luksResume mjolnir-secrets    # inject() resumes a suspended mapper
         fsfreeze -u /secrets
```

Three properties make this fit Mjolnir specifically:

1. **The encrypted volume is not root.** Root is virtio-fs (`root=myfs rootfstype=virtiofs`); the
   LUKS container is a separate loopback device. Suspending it cannot deadlock the guest — the
   usual `luksSuspend` footgun (suspending the device your resume tooling lives on) does not apply.
2. **The re-injection path already exists.** `maybe_unlock_secrets/2` (`vm.ex:2422`) already
   delivers the passphrase over vsock on every boot *and* every dormancy wake. Thaw is a wake with
   two extra guest-agent calls.
3. **It composes with both secrets modes.** `:managed` re-injects from `SecretEscrow`
   automatically. `:persistent` requires the owner's Iroh peer at thaw — which is the same
   requirement it already has at boot, and is the honest semantics for that tier.

**Residual exposure, stated honestly:** plaintext *data* read from the volume before the freeze may
remain in the guest page cache and thus in the captured RAM. `fsfreeze` plus dropping caches before
suspend narrows this but does not eliminate it. The distinction that matters: the snapshot no
longer yields a **reusable unlock capability** for the volume or for any other snapshot of it. That
is a bounded, one-time data exposure instead of a total key compromise.

For defense in depth, encrypting the `.mem` directory to the owner's IdentiKey (via PRE, once §4
lands) remains worthwhile — it closes the page-cache residue too. But it is no longer load-bearing,
and it costs the cheap freeze/thaw shipped in `mjolnir-3y6.4`.

Whatever is chosen must be enforced **structurally**: a `:persistent` or `:managed` VM should have
the suspend/resume wrapped into the snapshot path itself, not left to callers being careful.

### 5.5 Replication and placement

- **Transport:** `btrfs send -p` per tenant subtree (mechanics in bead `mjolnir-qwp`). Snapshots
  are already created read-only where it matters, which `send` requires.
- **Placement registry:** `{tenant, snapshot} → [nodes]`, plus which node currently *runs* a VM.
- **Identity remapping on restore:** new CID, TAP, IP, possibly a new Iroh node key. This is the
  same problem as `mjolnir-8m3` (fork N VMs from one memory snapshot) — solve once, use twice.
- **Clustering:** libcluster + `:pg`, tracked as `mjolnir-6fn`.

---

## 6. The exit test

Per Duke's revenue protocol, this must pass: *can a user leave with their keys and data intact,
without permission?*

**Acceptance criterion, to be tested and not merely asserted:** a user holding their IdentiKey can
take a raw `btrfs send` stream of their tenant subtree, off Mjolnir infrastructure entirely, and
decrypt their tier-3 volumes without the server's participation.

Losing managed dormancy, the gateway, the fleet, and support on exit is fine — that is what paying
buys. Losing the ability to decrypt your own data is capture. Make this a test, not a hope.

---

## 7. Implementation order

1. **Identity binding** (`sub` → `identikey_fp`) — everything downstream depends on it
2. **Per-tenant subvolume trees** + qgroup quota — pure refactor, no crypto, immediately useful
3. **Memory-snapshot policy** — small, but the hole gets harder to close after tenants exist
4. **DEK wrapping to IdentiKey** via recrypt PRE — makes `:persistent` genuinely sovereign
5. **Biscuit capabilities** (rbac-design Phase 1) — unlocks sharing
6. **`btrfs send` replication** + placement registry — the multi-node payoff

Steps 1–3 are plumbing and buy real isolation with no Rust integration. Step 4 is where the recrypt
dependency bites, and it is shared with `mjolnir-9bq.5` (Sites keyspace/recipients).

---

## 8. Open questions

- **Key rotation and recovery.** If a user rotates their IdentiKey, every wrapped DEK must be
  re-wrapped. If they *lose* it, is there a recovery path, and does offering one violate §6?
- **Fingerprint or subject as the storage path component?** The layout above uses `identikey_fp`,
  which makes the path self-describing but breaks if the binding changes. A stable internal
  tenant UUID is the alternative.
- **Quota enforcement point** — `btrfs qgroup` (kernel, hard) vs. application-level accounting
  (flexible, bypassable)?
- **Does `@base` stay global or get per-tenant private base images?** Private bases reintroduce the
  per-tenant storage cost that §4 avoids, but tenants will want custom golden images.
- **Cross-tenant snapshot sharing** — a Biscuit grants *access*, but the recipient still cannot
  decrypt tier 3 without a PRE re-encryption key. Sharing a snapshot is therefore a two-step
  operation. Is that acceptable UX, or does it need a single verb?
- **Capability root binding** — server key or owner key? (Carried over from `rbac-design.md`;
  under multi-tenancy the answer matters more, since server-key binding means the operator can
  mint any tenant's capability.)
