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
`/etc/mjolnir/vm.json` next to `api_url` and `blob_door_url`.
`configure_identity` locators SHALL be a map (not a growing
positional argument list) before `aie_url` is added
(`lib/mjolnir/vsock/protocol.ex` today takes `api_url` then optional
`blob_door_url`). When `/dev/accel/accel0` is missing or the unit
is stopped, the key is omitted. Other sidecars stay as they are.

Audience for execute proof is this host's mint-root fingerprint.
The overlay origin `http://10.200.0.1:<port>` is the same on every
Mjolnir host and SHALL NOT be the sole audience.

Install rides `just deploy` (blob-door lesson: no new just verb per
sidecar). Bind is dummy-mjolnir, fail-closed, never `0.0.0.0` and
never `lo`.

HTTP path shape (OpenAI-compat vs native IRON) is
`add-aie-guest-offer`. Architecture requires HTTP on the locator
origin and a `mj` share/run surface.

## Decision 4 — Execute proof, then injected holder

Possession of Biscuit bytes is not execute. The **BEAM decides**;
the sidecar **enforces**. `Mjolnir.Secrets.Nonces`,
`Mjolnir.Biscuit.authority/0`, SecretStore leaf verify, the
offering-VM allowlist, and VM liveness live in the orchestrator.
The sidecar is a separate unit (not an OTP worker, not
`mjolnir-03x`). It SHALL NOT consume nonces or load mint roots
itself.

The sidecar hashes the job and calls enqueue then admission on a
**dedicated AIE-admit unix socket** (`/run/mjolnir/aie-admit.sock`).
That listener is not `/run/mjolnir/operator.sock`. The operator
socket stays chmod `0600`, owner root, pipeline
`Mjolnir.API.OperatorPipeline`, and grants all operator scopes
(`lib/mjolnir/application.ex:141–165`,
`lib/mjolnir/api/operator_pipeline.ex:4–7`,
`lib/mjolnir/api/auth.ex:69–73`). The sidecar user SHALL NOT be
given that credential. The admit pipeline SHALL NOT set
`:mjolnir_operator` and SHALL expose only enqueue and admission
routes. The admit-socket credential is mode `0660`, owner root,
group a dedicated AIE group (`mjolnir-aie`); the sidecar OS user
is a member of that group. An unrelated uid SHALL NOT connect.
A connection on the admit socket SHALL NOT grant VM spawn, exec,
kill, or snapshot routes. After BEAM or listener restart, bind
then chmod/chown to those exact values; restart SHALL NOT widen
access or reuse the operator pipeline.
`add-aie-host-sidecar` owns the listener, pipeline, credential,
and the sidecar client.

The **BEAM** owns authenticated pending-request state (in-memory
table; same process lifetime as `Mjolnir.Secrets.Nonces`).
Enqueue, on a valid proof, consumes the client nonce once, stamps
enqueue time, stores the complete verified frame (biscuit digest,
audience, offer resource including incarnation, catalog design
id, input Blake3, idempotency key, holder fingerprint), and
returns a `pending_id` bound immutably to that frame and stamp.
Admission names `pending_id` plus an **occupancy `attempt_id`**
(sidecar-generated at a successful try-lock) and SHALL NOT
consume a nonce. Admission SHALL refuse a missing, expired,
cancelled, already-dispatched, or unknown `pending_id`, and
SHALL refuse when the sidecar's job digest or resource does not
equal the stored frame. Admission without a successful enqueue
is refused. The transition pending → dispatched is atomic,
happens at most once, and is bound to that `attempt_id`.
Concurrent admissions of the same `pending_id` yield one
dispatch; the others fail.

**Historical status is not load authority.** BEAM `dispatched`
records that an admission decision happened. The sidecar MAY
load only when all of these hold: it still holds the occupancy
flock for that `attempt_id`; that attempt's admit deadline has
not expired; it has a live success for `(pending_id, attempt_id)`
received in that window (first reply or lost-reply retry of the
same pair); no load has started for this `pending_id`. The
sidecar suppresses duplicate loads. After deadline expiry, lock
release, cancel, or restart, that attempt is abandoned. A retry
or late success for an abandoned attempt MAY report historical
status and SHALL NOT authorize a load. The same `pending_id`
SHALL NOT authorize a later occupancy attempt. Recovering after
abandonment requires a fresh client nonce and a new enqueue;
that admission revalidates current policy (Decision 6). v1 does
not recover every accepted job whose reply was lost after the
lock was released. BEAM or sidecar restart invalidates every
`pending_id`; the client MUST obtain a fresh nonce and enqueue
again. Cancel and max-queue-age expiry make the id unusable;
reuse is refused. Retries SHALL NOT reset enqueue time. After
enqueue, `pending_id` is the retry identity within one attempt;
a second enqueue with a new nonce is a distinct pending row.
`add-aie-host-sidecar` owns the table, two-call API, and
duplicate-load suppression; `add-aie-guest-offer` owns guest
retry of the same `pending_id` while the attempt is live.
`native/mjolnir_biscuit` still has no HTTP.

Profile `mjolnir/aie-execute/v1`. Frame fields: biscuit, nonce,
audience (this host's mint-root fingerprint), offer resource
(`<owner_fp>/<offer_id>/<incarnation>`), catalog design id, Blake3
of the submitted input bytes, and an idempotency key. The Ed25519
public key in the proof is the holder; its §5 fingerprint is
computed by the BEAM, never taken from the token. The proof has no
timestamp; the BEAM stamps enqueue time and refuses admission
after a maximum queue age (host policy; default 60s to match
nonce TTL).

`holder` and `member` facts SHALL be verifier-injected by the
BEAM. A token that asserts them SHALL still fail unless the
verifier injects matching facts. Guild membership is that inject,
not a new Datalog check in `mint` / `authorize` (those stay one
fingerprint plus `inject_holder`).

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
`owner_fp` (the being offers its own host capacity) **and** that
VM id is on this host's operator-held allowlist of offering VMs.
A valid signature over someone else's VM id is refused. A
self-signed offer from a guest not on the allowlist is refused at
publish, mint, and admission. The allowlist is the denominator
for "claims on capacity" on this host.

Mint issuer is this host's durable production Biscuit root
(`Mjolnir.Biscuit.authority/0`), on the being's authorized
instruction. The BEAM verifies execute tokens against that root
only. A foreign issuer is refused. Mint reads the current verified
leaf and embeds that leaf's incarnation in the right.

v1 incarnation revocation is **whole-offer**. There is no per-holder
expiry on `mint` (resource + operation only). Revoking one holder
of a personal offer means replacing the leaf and re-minting the
others. Accepted for v1.

`add-aie-keyspace-claims` owns envelope serialization. SecretStore
today recognizes specific record types (`lib/mjolnir/secret_store.ex`
canonical_bytes sniff); a new type is that node's problem, not a
stub.

Withdrawal is a tombstone in the same key. The leaf carries a
strictly increasing sequence. The tombstone is retained as a floor.
Put of a leaf whose sequence is at or below that floor is refused,
including re-put of the exact retired bytes (which would recreate
the old incarnation). Replacement is a new leaf at that key (new
bytes, new sequence, new incarnation). Admission compares the
token incarnation to Blake3 of the current verified leaf.
Mismatch, tombstone, or missing leaf refuses before load.
`add-aie-keyspace-claims` owns sequence/tombstone encoding;
`add-aie-guest-offer` (mint) and `add-aie-host-sidecar` (admission
via BEAM admit) share the binding.

## Decision 6 — Admission-time policy

The verified offer record at **admission** is authoritative.
Enqueue time is not. Work already loaded may finish after
withdrawal; queued work does not start.

Occupancy vs membership order: **try-lock, revalidate under a hard
deadline, then load or release.** Each successful try-lock starts
a new occupancy `attempt_id`. Do not wait on the IRON flock
while a membership lookup is in flight. If try-lock fails, wait,
then try-lock again and revalidate from scratch. Enqueue-time
membership SHALL NOT authorize admission. A cached BEAM
`dispatched` from an earlier attempt SHALL NOT skip that
revalidation or authorize a load (Decision 4).

Guild-scoped offers: the holder proof key is the **consumer VM's**
IdentiKey. A human guild member does not put their key in the
guest. Membership is a trusted lookup of `member(<ks>, <member_pk>)`
plus a member-signed **delegation leaf** naming that consumer VM
holder (`add-guild-compute-holder` owns encoding). The lookup and
delegation are revalidated at each successful try-lock. Response
`issued-at` must be within provider max-age. Non-member, missing
delegation, expired, or unavailable fails closed. Token-authored
`member` facts do not count. Personal-fp offers skip the lookup
and the delegation.

A personal-to-guild replacement changes the leaf, so the old
incarnation fails at admission even if the holder is a current
member. A removed member fails at the admission lookup. This is
authoritative revalidation, not delayed revocation.

## Decision 7 — Occupancy lock lifetime

The lock is IRON Lab's occupancy flock (same identity `ironlab`
and the sidecar use). After a successful try-lock and a passing
admit, hold from immediately before catalog-design load until the
XRT worker is reaped and the device is quiescent. Timeout and
cancel wait for that quiescence before releasing. If quiescence
cannot be established, new execute is refused until an operator
clears the fence. Maximum wall time is on the signed offer leaf;
the sidecar SHALL kill the worker at that bound.

The lock is advisory. A host `just hello` that ignores it can still
clobber; the sidecar coordinates with cooperating IRON entry points
only.

`aie-npu-path` did not prove this. Remaining verification is
`add-aie-host-sidecar`.

## Decision 8 — v1 job and sidecar user

A v1 job is a **host-catalog design id** plus bounded input bytes.
The sidecar SHALL NOT load a guest-authored xclbin in this DAG.
Catalog contents (which IRON designs exist) are `add-aie-host-sidecar`.
The signed leaf MAY list allowed design ids and MUST carry a
maximum wall time.

The sidecar process SHALL run as a dedicated OS user with access
to `/dev/accel/accel0`, not as root. That user is in group
`mjolnir-aie` so it can connect to `aie-admit.sock`. It SHALL
NOT run as root and SHALL NOT be given `operator.sock`. Install
is still `just deploy`.

## ADR 0015 one screen

1. Sidecar on `:host_api_ip:7422`, INPUT, locator `aie_url` in a
   locator map. Dedicated OS user, not root.
2. No guest accel/DRM node. No VFIO for this capability.
3. Offer principal = VM IdentiKey on an operator allowlist; mint
   issuer = this host's production Biscuit root.
4. BEAM admits on `/run/mjolnir/aie-admit.sock` (not operator.sock);
   sidecar enforces. Pending table on the BEAM; `pending_id`
   binds the verified frame. Load needs a live admit on the
   current occupancy `attempt_id`; cached dispatched is status
   only. Redeem-shaped proof; audience is mint-root fp. Holder
   = consumer VM; guild = injected member plus member-signed
   delegation.
5. Canonical resource `{owner_fp, offer_id}` plus leaf-hash
   incarnation and increasing sequence. Tombstone is a floor.
   Whole-offer revocation for v1.
6. v1 job = host-catalog design id + bounded input. Occupancy:
   try-lock, revalidate under deadline, load until quiescence.
7. Off = no device or unit down; omit locator.

## Unverified hypotheses

- Spike: `aie-npu-path` overlay RPC — **go**
  (`docs/spikes/aie-npu-path/finding.md`).
- Spike: `aie-occupancy-lock` sidecar and ironlab share one flock through timeout, cancel, and restart — go
  (`docs/spikes/aie-occupancy-lock/finding.md`). Owned by `add-aie-host-sidecar`. Worker inherits the flock fd. The RPC spike is not this evidence.
