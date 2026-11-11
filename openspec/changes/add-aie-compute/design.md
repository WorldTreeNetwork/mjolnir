# Design

## Decision 1 — Host sidecar, not VFIO

The NPU stays bound to `amdxdna` on the host. Guests talk HTTP to a
process on `:host_api_ip` (default `10.200.0.1` on `dummy-mjolnir`).
Guest TCP is INPUT. Default port is `7422` (`:aie_compute_port`).
The spike proved this path: overlay RPC ran IRON `npu2` vector-add
with `Match: True` and the guest had no `/dev/accel`.

Cloud Hypervisor `vm.create` has no PCI section today
(`lib/mjolnir/cloud_hypervisor/config.ex`). Hardware-requirements §5
is GPU VFIO. Krackan NPU IOMMU group 26 is only `0000:c3:00.1`, but
the usable Linux path is host KMD + XRT, not a guest driver.

Rejected: VFIO passthrough, virtio-accel, copying `/dev/accel` into
the rootfs, OTP-only `mjolnir-03x` as the share vehicle.

## Decision 2 — VM being is the principal

The offer is named by the sharing VM's IdentiKey (the being). The
sidecar process is not an IdentiKey. Guilds and biscuits grant
against the offer, which names that being. This matches "share via
a mjolnir vm" and honor-being as the long-lived identity.

The host still runs the kernel and XRT. Isolation is grant-time
(who may execute), occupancy (one loaded design), and "no device
node in the guest". It is not a confidentiality boundary against
the host.

## Decision 3 — Locator, Off, install

When the sidecar is up, every boot injects `aie_url` into
`/etc/mjolnir/vm.json` next to `api_url` and `blob_door_url`
(`configure_identity` / `lib/mjolnir/vm.ex`). When `/dev/accel/accel0`
is missing or the unit is stopped, the key is omitted. Other
sidecars stay as they are.

Install rides `just deploy` (blob-door lesson: no new just verb per
sidecar). Bind is dummy-mjolnir, fail-closed, never `0.0.0.0` and
never `lo`.

HTTP path shape (OpenAI-compat vs native IRON) is
`add-aie-guest-offer`. Architecture requires HTTP on the locator
origin and a `mj` share/run surface.

## Decision 4 — Execute proof, then injected holder

Possession of Biscuit bytes is not execute. The sidecar (not
`native/mjolnir_biscuit`) authenticates the request the same way
redeem does: the caller signs a domain-separated, length-prefixed
frame, then the verifier injects `holder("<fp>")` and authorizes.

Profile `mjolnir/aie-execute/v1`. Frame fields: biscuit, nonce,
audience (this host's mint-root fingerprint plus `aie_url` origin),
offer resource (`<owner_fp>/<offer_id>/<incarnation>`), Blake3 of
the submitted job bytes, and an idempotency key. Nonce is
single-use (`Mjolnir.Secrets.Nonces`). The Ed25519 public key in
the proof is the holder; its §5 fingerprint is computed by the
verifier, never taken from the token.

`holder` and `member` facts SHALL be verifier-injected. A token that
asserts them SHALL still fail unless the verifier injects matching
facts. HTTP stays out of the biscuit crate.

Right on the token is
`right("<owner_fp>/<offer_id>/<incarnation>", "aie-execute")`.
`offer_id` alone is not the resource. The caller cannot choose
`incarnation`; mint copies it from the current verified leaf.

## Decision 5 — Canonical offer and mint issuer

SecretStore keyspace fingerprint (`IdentiKey.fingerprint/1`, Blake3
of the raw pubkey) and holder fingerprint (auth-challenge v1 §5)
are different namespaces. The offer leaf stores both: `owner_fp` for
the keyspace path, and the being's 32-byte Ed25519 pubkey so execute
can derive the §5 holder fp. They are not interchangeable.

Canonical resource is `{owner_fp, offer_id}` under that owner's
keyspace. Two owners may reuse a local `offer_id`; their rights do
not collide. Grant identity adds `incarnation`: Blake3 of the
canonical signed offer-leaf bytes. Local `offer_id` may be reused
after replacement; an incarnation SHALL NOT authorize a later leaf.

The signed leaf names the VM id / being that offers. Publish and
mint are allowed only when that VM's IdentiKey is the same key as
`owner_fp` (the being offers its own host capacity). A valid
signature over someone else's VM id is refused.

Mint issuer is this host's durable production Biscuit root
(`Mjolnir.Biscuit.authority/0`), on the being's authorized
instruction. The sidecar verifies execute tokens against that root
only. A foreign issuer is refused. Mint reads the current verified
leaf and embeds that leaf's incarnation in the right.

`add-aie-keyspace-claims` owns envelope serialization. SecretStore
today recognizes specific record types (`lib/mjolnir/secret_store.ex`
canonical_bytes sniff); a new type is that node's problem, not a
stub.

Withdrawal is a tombstone in the same key. Replacement is a new
leaf at that key (new bytes, new incarnation). Admission compares
the token incarnation to Blake3 of the current verified leaf.
Mismatch, tombstone, or missing leaf refuses before load. A
tombstone followed by a new leaf is a new incarnation; verifier
restart does not revive an old grant because incarnation is a
function of durable leaf bytes. `add-aie-keyspace-claims`,
`add-aie-guest-offer` (mint), and `add-aie-host-sidecar` (admission)
share this binding. Field encoding stays with those children.

## Decision 6 — Admission-time policy

The verified offer record at **admission** (the moment the occupancy
lock is acquired, before xclbin load) is authoritative. Enqueue
time is not. A queued job revalidates proof, offer incarnation, and
membership at admission. Work already loaded may finish after
withdrawal; queued work does not start. Enqueue consumes the client
nonce once; admission revalidation of that queued request SHALL NOT
consume a second client nonce (`Mjolnir.Secrets.Nonces` is
process-local and consume-once).

Guild-scoped offers: membership is **revalidated at admission** by
a trusted lookup (`add-guild-compute-holder`). Enqueue-time
membership evidence SHALL NOT authorize admission. The lookup is
bound to the same public key as the holder proof and to the
keyspace id on the verified offer. The lookup response may be used
only for that admission attempt, and only if its provider
`issued-at` is within the provider's max-age (config owned by
`add-guild-compute-holder`; measured from `issued-at` to admission
time). A lookup that reports non-member, or is missing, expired, or
unavailable, fails closed — even if older evidence is still within
TTL. Token-authored `member` facts do not count. Personal-fp offers
skip the lookup.

A personal-to-guild replacement changes the leaf, so the old
incarnation fails at admission even if the holder is a current
member. A removed member fails at the admission lookup. This is
authoritative revalidation, not delayed revocation.

## Decision 7 — Occupancy lock lifetime

The lock is IRON Lab's occupancy flock (same identity `ironlab`
and the sidecar use). Hold from immediately before xclbin load
until the XRT worker is reaped and the device is quiescent. Timeout
and cancel wait for that quiescence before releasing. If quiescence
cannot be established, new execute is refused until an operator
clears the fence.

The lock is advisory. A host `just hello` that ignores it can still
clobber; the sidecar coordinates with cooperating IRON entry points
only.

`aie-npu-path` did not prove this. Remaining verification is
`add-aie-host-sidecar`.

## ADR 0015 one screen (owed by act)

1. Sidecar on `:host_api_ip:7422`, INPUT, locator `aie_url`.
2. No guest accel/DRM node. No VFIO for this capability.
3. Offer principal = VM IdentiKey; mint issuer = this host's
   production Biscuit root on that being's instruction.
4. Canonical resource `{owner_fp, offer_id}` plus leaf-hash
   incarnation on the execute right. Execute = redeem-shaped
   request proof, then injected holder; guild = injected member
   from an admission-time lookup.
5. Capacity = signed keyspace claim; admission-time policy;
   replacement mints a new incarnation.
6. Occupancy flock from load until worker quiescence.
7. Off = no device or unit down; omit locator.

## Unverified hypotheses

- Spike: `aie-npu-path` overlay RPC — **go**
  (`docs/spikes/aie-npu-path/finding.md`).
- Spike: `aie-occupancy-lock` sidecar and `ironlab` share one flock
  through timeout, cancel, and restart — unverified (low, none).
  Owned by `add-aie-host-sidecar`. The RPC spike is not this evidence.
