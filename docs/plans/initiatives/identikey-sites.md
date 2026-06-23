# IdentiKey Sites: Static Content over Iroh, Backed by Recrypt

**Status:** Design (2026-05-13)
**Owner:** Duke
**Phase 1 target:** Public mode
**Related:**
- `~/work/IdentiKey/recrypt/docs/architecture.md`
- `~/work/IdentiKey/recrypt/docs/verification-architecture.md`
- `~/work/IdentiKey/recrypt/docs/hybrid-encryption-architecture.md`
- `docs/plans/initiatives/option-c-dual-layer-architecture.md` (gateway / Iroh routing)

---

## 1. Executive summary

Each Mjolnir host runs a sidecar process under the Elixir supervision tree that
serves IdentiKey-owned static content over Iroh-QUIC. The existing gateway
already maps `<iroh_id>.vm.worldtree.network` to a dialed Iroh endpoint; the
sites server simply binds Iroh endpoints alongside VMs. Content is stored as
content-addressed, Bao-verified chunks on BTRFS using the recrypt encryption
stack. Snapshots are immutable Gordian-enveloped manifests signed by the owning
IdentiKey. Publishing a new version is "update a signed HEAD pointer"; replicas
reconcile by comparing signed pointers and pulling missing chunks via
`btrfs send` or recrypt's S3 backend.

The system supports **three serving modes** that share a single chunk layer and
manifest format:

1. **Public** — symmetric keys published in the snapshot manifest; site server
   decrypts on serve; plaintext to the browser over TLS via the gateway.
2. **Owner-only / capability-gated** — server streams ciphertext + outboard
   directly to clients holding the IdentiKey; the client decrypts.
3. **Shared / group** — recrypt's group-sharing primitive: server holds
   per-viewer recryption keys, recrypts the wrapped key (KEM) on each read,
   bulk ciphertext (DEM) untouched. Revocation is atomic.

All three modes use the same `EncryptedFile` envelope shape and the same
content-addressed BTRFS chunk store. Only the **key disclosure policy** differs.
This is the architectural unification that justifies treating "public static
site" as the same system as "encrypted group document".

The mental model is **IdentiKey ↔ IPNS, snapshot hash ↔ IPFS CID**, except the
gateway already resolves Iroh IDs directly so there is no DHT propagation step.
Publishing is a local operation on the host that owns the IdentiKey's stable
endpoint.

**Three-layer verification.** Every published snapshot is independently
verifiable along three axes:

1. **Bao / Blake3** — bytes match the signed `bao_hash`. Streaming, parallel,
   tamper-evident per chunk.
2. **MultiSig** — manifest was signed by the claimed IdentiKey (ED25519 +
   ML-DSA-87, dual-stack classical + post-quantum).
3. **OpenTimestamps** — the snapshot hash was anchored to Bitcoin at a known
   time. Trust-minimized provenance; anti-backdating.

The three layers compose: "IdentiKey X signed exactly these bytes at no later
than time T."

---

## 2. Vocabulary

| Term                  | Definition                                                                                                                                                                   |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **IdentiKey**         | A persistent identity keypair bundle (ED25519 + ML-DSA-87 + PRE public key). Owns sites, signs records.                                                                       |
| **Keyspace**          | The namespace of signed records owned by an IdentiKey. Addressed by `(identikey_fingerprint, record_type, name)`. The Mjolnir SecretStore is a keyspace registry.            |
| **Site**              | A directory of static content owned by an IdentiKey. Multiple sites per IdentiKey are supported via the `name` field.                                                         |
| **Snapshot**          | An immutable Gordian-enveloped manifest binding `path → bao_hash` for every file in a site, plus serving metadata. Signed by the owning IdentiKey. Identified by its own Blake3 hash. |
| **HEAD**              | A signed record in the IdentiKey's keyspace pointing at the currently-published snapshot. Mutable, monotonic.                                                                |
| **Stable endpoint**   | The Iroh endpoint whose secret key is derived from (or registered to) the IdentiKey. Reads HEAD on dial and serves whatever snapshot HEAD points at.                          |
| **Permalink endpoint** | An Iroh endpoint whose secret key is derived from a snapshot hash. Immutable: serves exactly that snapshot forever (or until the host garbage-collects it).                  |
| **Chunk**             | A ciphertext blob in content-addressed storage, keyed by the Blake3 hash of the ciphertext. Has a sibling `.obao` outboard for streaming verification.                       |
| **Mode**              | The key-disclosure policy attached to a snapshot: `public`, `gated`, or `group`. The chunk layer is uniform across modes.                                                     |

---

## 3. Architecture overview

```
+--------------------------------------------------------------------+
|                       BROWSER (untrusted)                          |
|  GET https://<identikey-or-hash>.vm.worldtree.network/path         |
+----------------------------------+---------------------------------+
                                   |
                                   | HTTPS
                                   v
+--------------------------------------------------------------------+
|                       GATEWAY (existing)                           |
|  - SNI / Host -> Iroh ID resolution                                |
|  - Dial Iroh endpoint, forward HTTP                                |
+----------------------------------+---------------------------------+
                                   |
                                   | Iroh-QUIC
                                   v
+--------------------------------------------------------------------+
|                       MJOLNIR HOST                                 |
|                                                                    |
|  +----------------------------------------------------------+      |
|  |             Mjolnir.Sites.Supervisor                     |      |
|  |                                                          |      |
|  |  +-----------------+   +-------------------------+       |      |
|  |  | Endpoints       |   |  Server (Bandit/Plug)   |       |      |
|  |  | - per-site Iroh |-->|  Routes:                |       |      |
|  |  | - per-snapshot  |   |   GET /<path>           |       |      |
|  |  +-----------------+   |   HEAD /<path>          |       |      |
|  |                        +-----------+-------------+       |      |
|  |                                    |                     |      |
|  |                                    v                     |      |
|  |  +-------------------+   +------------------------+      |      |
|  |  | Mjolnir.SecretStore|  |  Mjolnir.Sites.Store    |      |      |
|  |  | (signed records)   |  |  - LocalFileStorage     |      |      |
|  |  | reads HEAD ptr     |  |  - Bao verify on read   |      |      |
|  |  +-------------------+   +-----------+------------+      |      |
|  |                                      |                   |      |
|  |                                      | BTRFS reflink     |      |
|  |                                      v                   |      |
|  |                          +-----------------------+       |      |
|  |                          |  @sites/ subvolume    |       |      |
|  |                          |  (BTRFS, CoW)         |       |      |
|  |                          +-----------+-----------+       |      |
|  |                                      |                   |      |
|  |  +-------------------+                |                   |      |
|  |  | Replicator        |<---------------+                   |      |
|  |  | - btrfs send/recv |  to / from peers via SSH or Iroh   |      |
|  |  | - pointer gossip  |                                    |      |
|  |  +-------------------+                                    |      |
|  +----------------------------------------------------------+      |
+--------------------------------------------------------------------+
```

Key invariants:

1. **One chunk store per host.** All sites on that host share `@sites/blob/`.
   Reflinks make publishing free; deduplication is automatic because chunks are
   content-addressed by their ciphertext hash.
2. **Endpoints are cheap.** Binding a new Iroh endpoint per stable site or per
   permalink is a keypair derivation plus an Iroh `bind`. Hosts can serve
   thousands.
3. **The HEAD pointer is the only mutable state.** Everything else
   (chunks, manifests, snapshots) is immutable and content-addressed.

---

## 4. Storage layout

A single BTRFS subvolume per host:

```
@sites/
|-- blob/
|   `-- b3/
|       |-- <hash58>          ciphertext chunk (content-addressed by Blake3)
|       `-- <hash58>.obao     Bao outboard sibling
|
|-- manifests/
|   |-- <snapshot_hash58>         Gordian envelope: signed manifest
|   `-- <snapshot_hash58>.ots     OpenTimestamps proof (upgradeable)
|
`-- keyspace/
    `-- <identikey_fp58>/
        `-- sites/
            |-- <site_name>/HEAD          signed record: current snapshot hash + seq
            `-- <site_name>/config         (optional) per-site policy: mode, viewers, etc.
```

Notes:

- `blob/b3/` matches the recrypt `LocalFileStorage` layout, so we can use
  `recrypt-storage::LocalFileStorage` directly or via a thin Elixir wrapper that
  shells out to a Rust NIF / sidecar binary.
- `manifests/` could equivalently live under `blob/` (manifests are themselves
  content-addressed). Keeping them split makes operational inspection easier
  during early phases; we may consolidate later.
- `keyspace/` is the on-disk representation of the SecretStore. Each entry is a
  small file containing the Gordian envelope of a signed record.
- BTRFS snapshots of `@sites/` are how cross-host replication works
  (see §8).
- `.ots` files are the OpenTimestamps receipts for each snapshot hash. Initially
  written in "pending" state (calendar attestation only); upgraded to
  Bitcoin-anchored state by a background job as blocks confirm (see §6.1).

### Storage integration decision (spike mjolnir-9bq.1, 2026-06-22)

**Decision: delegate chunk storage to the `recrypt-storage` crate via the
`recrypt-server` HTTP sidecar (NOT a NIF). Ship the seam now; the live wiring is
deferred until recrypt-server grows content-addressed chunk routes.**

The seam is in place behind `Mjolnir.Sites.Store`:

- `Mjolnir.Sites.Storage` — behaviour (`put_chunk/3`, `get_chunk/1`, `has_chunk?/1`).
- `Mjolnir.Sites.Storage.Local` — **default** backend. BTRFS files, byte-for-byte
  the same layout as recrypt's `LocalFileStorage` (`blob/b3/<hash58>` + `.obao`).
  Keeps the unit suite green and recrypt-less hosts working.
- `Mjolnir.Sites.Storage.Recrypt` — HTTP adapter to the sidecar (scaffolded).
- Selected via `config :mjolnir, :sites_storage_backend` (default `…Storage.Local`);
  env override `MJOLNIR_RECRYPT_STORAGE_URL` flips to the Recrypt backend.

**Why sidecar over NIF:**

- `recrypt-storage::BlobStorage` already implements `put_with_outboard` /
  `get_with_outboard` / `delete_with_outboard` with real Bao outboards, and an
  S3/B2 backend (the `minio()` path-style ctor is the same code with a B2
  endpoint). recrypt-server already wires this up (`state.rs`,
  `routes/files.rs`).
- `recrypt-ffi` exposes **crypto only** (OpenFHE/liboqs/ed25519) — **no storage**.
  A NIF would mean either pulling OpenFHE into the BEAM release build, or a fresh
  rustler crate against recrypt-storage that still drags `aws-sdk-s3` + the
  recrypt git dependency into the BEAM build. The whole recrypt workspace **fails
  to compile on macOS** (OpenFHE/liboqs native deps), so a NIF would break local
  Mac development of Mjolnir.
- A sidecar keeps the BEAM build clean, lets recrypt-server own the S3/B2 backend,
  and crash-isolates storage — consistent with how Mjolnir already runs the
  hypervisor and Forgejo runner as separate processes.

**Gap that blocks going live (follow-up for recrypt repo):** recrypt-server's
current routes are insufficient. `POST /files` is multisig-auth-gated, hashes
server-side, and stores an **empty** outboard (never accepts a precomputed
`.obao`); `GET /files/{hash}` returns ciphertext only. The Recrypt adapter
expects unauthenticated content-addressed chunk routes that round-trip a
**precomputed** outboard, mapping 1:1 onto `put_with_outboard`/`get_with_outboard`:

    PUT /storage/blob/b3/{hash}        body = ciphertext
    PUT /storage/blob/b3/{hash}.obao   body = outboard
    GET /storage/blob/b3/{hash}        -> ciphertext
    GET /storage/blob/b3/{hash}.obao   -> outboard (404 = none)

The round-trip test (`test/mjolnir/sites/storage/recrypt_test.exs`, tagged
`:recrypt_storage`) documents this contract and is excluded from `mix test`. To
validate it, build + run recrypt-server **on the Mjolnir server** (not macOS),
add the routes above, then run
`MJOLNIR_RECRYPT_STORAGE_URL=… mix test … --include recrypt_storage`.

---

## 5. The manifest

A snapshot manifest is a Gordian envelope signed by the IdentiKey containing
(at minimum):

```
SnapshotManifest:
  version: 1
  identikey_fp:    base58 fingerprint of owning IdentiKey
  site_name:       string (e.g. "blog")
  mode:            "public" | "gated" | "group"
  created_at:      RFC3339 timestamp
  # Public mode only: a single per-snapshot seed; per-file sym_keys are
  # derived as HKDF(sym_seed, info=bao_hash). Absent for gated/group.
  sym_seed:        bytes[32] | null
  entries:         [
    {
      path:          "/index.html"
      content_type:  "text/html; charset=utf-8"
      bao_hash:      base58 Blake3 root over ciphertext
      ciphertext_size: u64
      plaintext_size:  u64
      nonce:           bytes[24]
      # Gated/group modes: per-file PRE-wrapped KeyMaterial.
      # Public mode: ABSENT (sym_key derived from snapshot-level sym_seed).
      wrapped_key:     EnvelopeBytes | null
    },
    ...
  ]
  signatures: MultiSig (ED25519 + ML-DSA-87) over the canonical manifest body
```

The snapshot's identity is the Blake3 hash of its envelope bytes. That hash is
the anchor point for the entire system. It is:

- the URL component of the permalink endpoint
  (`<snapshot_hash58>.vm.worldtree.network`), via a snapshot-hash-derived Iroh
  keypair;
- the value the stable endpoint's HEAD pointer carries; and
- the hash submitted to OpenTimestamps at publish time (see §6.1).

**Why per-snapshot `sym_seed` for public mode but per-file `wrapped_key` for
gated/group?** Size. A recrypt PRE envelope is kilobyte-scale; carrying one
per file would make a 10k-file site's manifest tens of MB, fetched on every
cold-cache dial. In public mode the sym_keys are not secret anyway, so a single
32-byte seed + HKDF derivation gives every file its own key with no per-file
manifest overhead. In gated/group modes per-file granularity is the whole point
(per-file revocation, per-file recryption), and private sites are typically
small enough that kilobyte-scale per-file envelopes are fine.

---

## 6. The three modes

The three modes differ **only** in what `sym_disclosure` contains for each
entry and in what the server does on a `GET`.

### 6.1 Public mode (Phase 1)

**Disclosure:** the snapshot manifest publishes a 32-byte `sym_seed` in the
clear. Per-file symmetric keys are derived as
`sym_key = HKDF(sym_seed, info=bao_hash)`. Anyone with the manifest can decrypt
any chunk.

**Why bother encrypting at rest then?** Two reasons:
1. Uniform chunk format across all three modes. One serve path, one verification
   path, one storage layout. The chunk store is shared across public, gated,
   and group sites.
2. Bao integrity binding works the same way — the manifest signature
   transitively authenticates every `bao_hash`, which in turn authenticates the
   chunk bytes via streaming Bao verification.

**Serve path:**

```
1. Browser GET / -> gateway -> Iroh dial of stable endpoint
2. Sites server resolves stable endpoint -> IdentiKey fingerprint
3. SecretStore.read(identikey_fp, "sites/<name>/HEAD") -> snapshot_hash
4. Load manifests/<snapshot_hash>, verify signature (cached after first load)
5. Look up path in manifest entries
6. Stream chunk bytes from blob/b3/<bao_hash>, verifying against .obao
7. Derive sym_key = HKDF(snapshot.sym_seed, entry.bao_hash); decrypt with
   XChaCha20(sym_key, entry.nonce)
8. Write plaintext to the Iroh stream
9. Gateway terminates TLS and forwards to browser
```

**Publishing flow:**

```
1. Author runs `recrypt-cli` (or future `mjolnir-sites publish`) locally:
   - Generates a random sym_seed (32 bytes)
   - Walks the source directory; for each file:
     - Derive sym_key = HKDF(sym_seed, file_hash_pre_encryption)
     - XChaCha20-encrypt with a fresh nonce -> ciphertext
     - Bao-hash ciphertext -> (bao_hash, .obao)
   - Builds the manifest with mode="public", sym_seed, and per-file entries
   - MultiSig-signs the manifest with the IdentiKey
2. Author pushes to a Mjolnir host:
   - POST /sites/<identikey_fp>/<name>/snapshot { manifest_envelope }
   - Server stores manifest, walks entries, requests missing chunks
3. Server uploads chunks via streaming PUT to /sites/blob/<bao_hash>
   - Verifies bao_hash on receive; rejects mismatches
4. Server submits snapshot_hash to OpenTimestamps -> stores .ots receipt
   (see §6.1.1 below)
5. Once all chunks present:
   - POST /sites/<identikey_fp>/<name>/HEAD { signed_record }
   - Server verifies signature, sequence number monotonic; commits
6. Replicator gossips the HEAD update + new chunks to peers
```

**Cache:** After first decrypt, the host may cache plaintext chunks under
`@sites/plaintext-cache/` keyed by `bao_hash`. This is a pure optimization;
correctness is independent of the cache.

**Failure modes:**
- Missing chunk: 503 (chunk replication in progress) or 404 if the manifest is
  authoritative and the chunk is genuinely lost (corruption / disk failure —
  triggers self-heal from peers).
- Manifest signature invalid: 500, log loudly, refuse to serve. The host should
  never have accepted such a manifest.
- HEAD sequence regression: ignore the update.

#### 6.1.1 OpenTimestamps anchoring

Every published snapshot has its hash submitted to OpenTimestamps calendar
servers. The resulting `.ots` proof is stored as a sibling of the manifest
(`manifests/<snapshot_hash58>.ots`) and is part of the snapshot's public
record.

**Submission, at publish time:**

```
1. Server has stored manifests/<snapshot_hash58>
2. Submit snapshot_hash to N OpenTimestamps calendar servers in parallel
3. Receive N partial receipts; merge into a single .ots file
4. Write atomically to manifests/<snapshot_hash58>.ots
5. State: "pending" — calendar attestation only, not yet Bitcoin-anchored
```

**Upgrade, asynchronously:**

A `Mjolnir.Sites.TimestampUpgrader` GenServer scans `manifests/*.ots`
periodically (e.g. every 30 minutes). For each pending receipt:

```
1. Ask the calendar server whether the Bitcoin commitment has confirmed
2. If yes, fetch the Bitcoin block proof and append to the .ots file
3. Receipt is now self-contained and Bitcoin-verifiable without trusting any
   calendar server
```

In practice the first upgrade lands ~1 Bitcoin block after publish (median
~10 min) and subsequent upgrades deepen the commitment as more blocks confirm.

**Verifier stack** (any third party, including a hostile one):

| Layer | What it proves | How to verify |
| ----- | -------------- | ------------- |
| Bao   | Bytes match `bao_hash`         | `bao::decode` against signed `bao_hash` |
| MultiSig | Manifest signed by IdentiKey | ED25519 + ML-DSA-87 verify over canonical manifest body |
| OpenTimestamps | Snapshot hash anchored to Bitcoin at time T | `ots verify <snapshot>.ots` against a Bitcoin node or trusted explorer |

Composed: **"IdentiKey X signed exactly these bytes at no later than time T,
and the bytes have not been altered since."** That statement is verifiable
offline with only the manifest envelope, the chunks, and the `.ots` file —
no trust in the serving host required.

**Properties this enables:**

- **Anti-backdating:** an attacker who later compromises the IdentiKey cannot
  produce a snapshot that appears to predate the compromise — they would have
  to predict the Bitcoin block hash from before they had the key, which is
  computationally infeasible.
- **Fork detection:** if two snapshots claim the same `(IdentiKey, site_name,
  sequence)`, their `.ots` proofs anchor to different Bitcoin times, making
  the fork auditable and orderable.
- **Provenance:** "this content existed in this form at this time" is a strong
  publishing claim and is the kind of thing the open web has structurally
  lacked.

**Trust model:** OpenTimestamps calendar servers can fail or be malicious, but
once the receipt is Bitcoin-anchored their honesty is no longer required. The
upgrader is the operational mechanism that moves receipts from
"trust-the-calendar" to "trust-Bitcoin-consensus" as quickly as Bitcoin blocks
allow.

### 6.2 Gated mode (Phase 2)

**Disclosure:** `sym_disclosure` is **absent** or `null`. The chunk is recrypt-
encrypted to the IdentiKey's PRE public key with no published key material. To
read, the client must obtain `wrapped_key` and decrypt it locally with the
IdentiKey secret key (or a delegated recrypt key — see §6.3).

**Serve path:**

```
1. Browser GET / -> gateway -> Iroh dial
   (gated sites typically don't use a browser at all; they use a recrypt-aware
    client that presents an IdentiKey-signed capability over Iroh)
2. Server authenticates the caller: Iroh node-id is bound to a known
   IdentiKey via the SecretStore, or the caller presents a Capability
   (identikey-storage-auth::Capability) signed by the owner
3. Server streams ciphertext + .obao directly; client verifies and decrypts
```

This is the **purest recrypt path** — the server is semi-trusted, never sees
plaintext, only forwards ciphertext to authenticated callers. Plaintext caches
from Phase 1 are NOT used; gated sites are always served from blob storage.

**Authentication:** the client's Iroh node-id is the auth principal. Mapping
`iroh_node_id -> IdentiKey` lives in the SecretStore as a record type
(`identikey/iroh-binding`), itself a signed claim by the IdentiKey.

**Use case:** private dashboards, personal notes, anything the owner publishes
for themselves or a small set of explicitly bound viewers.

### 6.3 Group mode (Phase 3)

**Disclosure:** `sym_disclosure` is absent. The site has an associated
**group** (recrypt's `Group` abstraction, Phase 9 sprint in the recrypt repo).
The group has members, each with their own IdentiKey. The site owner has
generated a per-member recryption key (`rk_owner_to_member_X`) and uploaded it
to the sites server.

**Serve path:**

```
1. Authenticated client (recognized as group member M) GET /
2. Server looks up the recryption key rk_owner_to_M
3. Server fetches manifest, locates per-file wrapped_key
4. Server calls HybridEncryptor::recrypt(rk_owner_to_M, wrapped_key)
   -> wrapped_key' (now decryptable by M)
5. Server streams { wrapped_key', ciphertext, .obao } to M
6. M decrypts with their own IdentiKey secret key
```

**Why this is interesting:**
- Bulk data (DEM) is uploaded once, byte-identical across all viewers.
- Per-viewer cost is the KEM recryption: a small lattice operation per file
  read, not per byte.
- **Revocation is atomic**: deleting `rk_owner_to_M` from the server makes M
  unable to decrypt future reads. M cannot retroactively read content they
  haven't already downloaded.
- The server NEVER sees plaintext or any owner secret key. It only ever sees
  recrypt keys (which by themselves cannot decrypt anything).

**Group membership management:** delegated to the recrypt
`identikey-storage-auth` service's `Group` types once the Phase 9 sprint
lands. Until then, group mode is documented but not implemented.

**Use case:** team docs, family photo albums, multi-tenant SaaS where each
tenant has a private static site shared with a small group.

### 6.4 Mode comparison

| Property                | Public               | Gated                  | Group                          |
| ----------------------- | -------------------- | ---------------------- | ------------------------------ |
| Server sees plaintext   | Yes (decrypts)       | No                     | No                             |
| Browser-compatible      | Yes (via gateway TLS)| No (custom client)     | No (custom client)             |
| Auth required           | None                 | IdentiKey or capability| Group membership               |
| Revocation              | N/A                  | Unbind Iroh node-id    | Delete recrypt key (atomic)    |
| Per-viewer KEM op       | No                   | No (client-side)       | Yes (server recrypts on read)  |
| Storage overhead        | Same as gated/group  | Baseline               | Baseline + recrypt keys        |
| Manifest key carriage   | Per-snapshot sym_seed| Per-file wrapped_key   | Per-file wrapped_key + per-member rk |
| OpenTimestamps anchor   | Yes (mandatory)      | Yes (mandatory)        | Yes (mandatory)                |
| Use case                | Public site / blog   | Personal / private     | Team / family / multi-tenant   |

Phase 1 implements public. Phases 2 and 3 reuse the chunk store, manifest
format, and gateway path unchanged.

### 6.5 Custom-domain aliases

Independent of the three modes, any site can be reached at a user-owned
domain (e.g. `blog.duke.io`) by depositing a signed alias record in the
IdentiKey's keyspace. The gateway resolves unknown Host headers by pulling
`/api/sites/aliases/lookup?host=<fqdn>` from Mjolnir, then forwards the
request to Mjolnir's API backend; Mjolnir's vanity-host plug maps the
Host header to `(identikey_fp, site_name)` and serves via the same
`Sites.Server.serve/3` path as `<iroh_id>.vm.worldtree.network`.

**Record shape** (key: `sites/<site_name>/aliases/<fqdn>`):

    %AliasRecord{
      version: 1,
      identikey_fp: "...",
      site_name: "blog",
      fqdn: "blog.duke.io",
      sequence: 1,
      created_at: ~U[...],
      signature: <ed25519 over canonical_signing_bytes>
    }

**TLS for vanity domains** is out of scope for this phase. Two practical
options for users today:
- Front the Mjolnir host with Cloudflare (or any reverse proxy) that
  terminates TLS and forwards plain HTTP.
- Wait for the planned HTTP-01 ACME pass that will extend the existing
  `acme.rs` in `mjolnir-gateway` (DNS-01 today via Cloudflare for the
  `*.vm.worldtree.network` wildcard).

**Why not auto-DNS-01 for vanity domains?** Because we'd need the user's
DNS API credentials. HTTP-01 needs nothing but the CNAME and port 80 —
that's the path forward.

---

## 7. The HEAD pointer (Mjolnir SecretStore)

The HEAD pointer is the only mutable per-site state. It is a record in the
SecretStore keyed by `(identikey_fp, "sites/<site_name>/HEAD")`.

```
HeadRecord:
  version: 1
  identikey_fp: base58
  site_name: string
  snapshot_hash: base58 Blake3 over the manifest envelope
  sequence: u64                # monotonic; increments per publish
  created_at: RFC3339
  signature: MultiSig (ED25519 + ML-DSA-87) over the canonical record body
```

The SecretStore (new module, `lib/mjolnir/secret_store.ex`) provides:

```
SecretStore.put(identikey_fp, record_type, name, envelope_bytes)
  - verifies the envelope's signature against the registered IdentiKey
  - verifies sequence > stored sequence (LWW-by-sequence)
  - atomically replaces the file under keyspace/<fp>/<type>/<name>

SecretStore.get(identikey_fp, record_type, name) -> envelope_bytes
  - reads the file; signature verification is the caller's responsibility on
    read (cheap), but stored bytes are always pre-verified at write time

SecretStore.list(identikey_fp, record_type_prefix) -> [name]
SecretStore.delete(identikey_fp, record_type, name)
  - delete records must themselves be signed tombstones (signed by IdentiKey)
```

Backing storage: BTRFS files under `@sites/keyspace/`. Small enough that
filesystem operations are fast; benefits from BTRFS snapshots for replication.

Note: this is **distinct** from the existing `secrets_mode` on `Mjolnir.VM`,
which is about *runtime injection of secrets into a guest VM over vsock*. The
SecretStore is the **durable signed-record layer** that the VM injection path
will eventually read from.

---

## 8. Replication

Cross-host replication has two pieces:

### 8.1 Pointer gossip

When a host accepts a new HEAD record (or any signed record), it fans it out to
configured peers over an Iroh control channel. Peers verify signature +
sequence and store-or-ignore. This is small, fast, and idempotent.

### 8.2 Chunk sync

When a peer accepts a new HEAD pointing at a snapshot it doesn't have:

1. Fetch the manifest envelope (small, single round-trip).
2. Diff manifest entries against local `blob/b3/`.
3. For missing chunks, **either**:
   - **Phase 1 / low-volume:** pull each chunk + outboard over HTTP from the
     publishing host (matches recrypt-storage S3 model; trivial to implement).
   - **Phase 2 / efficient:** issue `btrfs send` of the publishing host's
     `@sites/` snapshot since the last common parent, receive on the peer.
     This preserves reflinks and is incremental at the block level.

Phase 1 will start with HTTP pulls. The `btrfs send`/`receive` path is an
optimization that can be added once the system is in operation. Both modes
produce the same on-disk result.

### 8.3 Conflict model

Conflicts can only happen on HEAD records, never on chunks (chunks are
content-addressed and immutable). The conflict resolution is
last-writer-wins-by-sequence — if two HEAD updates with the same sequence
appear, the one with the larger snapshot hash wins (tie-break by lexical
order, purely so the resolution is deterministic across hosts). In practice,
sequence collisions only happen if the IdentiKey has been actively duplicated
across two publishing tools, which is operationally a misuse.

---

## 9. Endpoint binding and gateway integration

Each host runs `Mjolnir.Sites.Endpoints`, which on startup:

1. Enumerates all `(identikey_fp, site_name)` HEAD records in the SecretStore.
2. For each:
   - Derives or loads the **stable Iroh keypair** for this IdentiKey + site.
     (Decision: derived deterministically from the IdentiKey's signing key via
     HKDF, OR registered explicitly when the site is created. Leaning toward
     explicit registration so that an IdentiKey can run sites on hosts other
     than its primary one.)
   - Binds the Iroh endpoint and advertises it.
3. For each known snapshot hash, optionally binds a permalink endpoint derived
   from the snapshot hash.

The gateway is unchanged. It already resolves `<iroh_id>.vm.worldtree.network`
by dialing the Iroh node and forwarding HTTP-over-Iroh. The sites server
listens on the Iroh endpoint and serves HTTP — same shape as the VM PTY/HTTP
flow that already exists, just terminated on the host rather than a VM.

**Permalink endpoints are optional and lazy.** The host only binds a permalink
endpoint for snapshots that are still on disk; a snapshot that has been
garbage-collected from the chunk store is not addressable. This is the
operational difference between a permalink and a stable endpoint: permalinks
are best-effort and content-availability-bound.

---

## 10. Phasing

### Phase 1: Public mode end-to-end

Goals:
- `Mjolnir.SecretStore` GenServer + BTRFS-backed storage of signed records.
- `Mjolnir.Sites.Supervisor` + `Endpoints` + `Server` + `Store`.
- `Mjolnir.Sites.Store` wraps recrypt's chunk semantics: store ciphertext +
  outboard at `blob/b3/`, verify on read, content-addressed by Blake3.
- HTTP endpoints for: upload chunk, upload manifest, update HEAD.
- Serve path: dial -> resolve HEAD -> manifest -> chunks -> HKDF-derive
  sym_key -> decrypt -> stream out.
- OpenTimestamps integration:
  - Submission on snapshot upload (synchronous; failures are non-fatal but
    logged loudly).
  - `Mjolnir.Sites.TimestampUpgrader` GenServer polls pending receipts on a
    schedule and upgrades them to Bitcoin-anchored state.
  - Serve `.ots` files alongside manifests so any third party can verify.
- CLI / publish flow: probably initially just direct curl + `recrypt-cli`
  commands until a dedicated `mjolnir sites publish` exists.

Out of scope for Phase 1:
- Cross-host replication (single-host is fine for first deploy)
- Permalink endpoints (focus on stable endpoints first)
- Plaintext caching layer
- Group mode / gated mode

Deliverables:
- Working public site served from `https://<iroh_id>.vm.worldtree.network`
- Documented publish flow
- Each published snapshot has a Bitcoin-anchored `.ots` receipt within ~1 hour
- Test coverage for: chunk storage, manifest verification, HEAD update,
  signature failures, missing chunks, OTS submission + upgrade.

### Phase 2: Replication + gated mode

- Pointer gossip over Iroh between peer hosts.
- HTTP-pull chunk sync.
- Gated mode: capability/IdentiKey-based access, no server-side decrypt.
- Garbage collection: chunks not referenced by any live manifest can be
  swept after a grace period.

### Phase 3: Group mode

- Depends on recrypt's group-sharing sprint landing.
- Sites server holds per-member recryption keys.
- Server-side `recrypt()` of wrapped_key on each authenticated read.
- Atomic revocation by deleting the recrypt key.

### Phase 4: BTRFS send/receive replication

- Replace HTTP pulls with `btrfs send | btrfs receive` between hosts.
- Preserves reflinks and is block-level incremental.

---

## 11. Decisions log + remaining open items

### Decided (2026-05-13 design session)

1. **Stable endpoint keypair → explicit registration.** Per-host endpoint
   keypairs, stored as signed records in the SecretStore. Enables migration,
   staging/prod separation, and multi-host serving of the same IdentiKey
   without DHT collisions.
2. **Manifest key carriage → per-snapshot `sym_seed` (public), per-file
   `wrapped_key` (gated/group).** See §5 and §6.1. The split keeps public-mode
   manifests small (no kilobyte-scale PRE envelopes per file) while preserving
   per-file revocation semantics where it matters.
3. **Path resolution rules → minimal.** Exact match; if path ends in `/`, try
   `<path>index.html`; otherwise 404. No extension-stripping, no redirects, no
   custom error pages in Phase 1. Per-site `config` record can extend later.
4. **MIME types → stored in the manifest.** Bound by the manifest signature, so
   `Content-Type` is integrity-checked. Publish-time tool sniffs when extension
   is ambiguous.
5. **Compression → deferred from Phase 1.** Authors who care can pre-compress
   and declare `content_encoding` per entry. Server-side gzip is Phase 2+.
6. **Quota / rate limiting → out of scope for Phase 1.** Phase 1 is
   single-tenant (Duke's IdentiKey on Duke's hosts). Required before opening
   publish to third-party IdentiKeys.
7. **OpenTimestamps → mandatory across all modes.** See §6.1.1. Submission at
   publish, background upgrader for Bitcoin anchoring. Trust-minimized
   provenance is core to the system, not an optional add-on.
8. **Custom-domain aliases → signed records + pull-based gateway resolver.**
   Site owners add aliases by signing `(identikey_fp, "sites/<name>/aliases/<fqdn>")`
   records. Gateway pulls from Mjolnir's `/api/sites/aliases/lookup` endpoint
   on unmatched Host headers. Cache+invalidate is an optional separate caching
   reverse proxy, not in the critical path. TLS for vanity domains is deferred
   to a later pass (HTTP-01 via gateway port 80 is the natural future path).

### Remaining open items

- **Sub-manifest splitting**: at what size do we split snapshot manifests for
  very large sites? Not a Phase 1 concern. Revisit if a real manifest crosses
  ~10 MB; until then, single-document manifests are simpler and adequate.
- **OTS calendar server selection**: how many, which ones, default config? Use
  the OpenTimestamps client's default calendar list for Phase 1; revisit if any
  prove unreliable.
- **OTS verification on serve**: does the serve path check `.ots` validity on
  every read, or only at publish-time? Phase 1: only at publish-time
  (correctness check), serve `.ots` to clients on request and let them verify.
  Per-request OTS verification would dwarf serve latency.
- **Phase 1 single-host deployment target**: which specific host, which BTRFS
  subvolume, which Iroh keypair-to-IdentiKey binding for Duke's first site?
  Operational, not architectural — settle in the implementation kickoff.

---

## 12. Why this is the right system

- **Reuses existing Mjolnir primitives**: BTRFS reflinks, Iroh endpoints,
  gateway routing, Elixir supervision. Almost nothing new at the
  infrastructure layer.
- **Reuses recrypt entirely**: the chunk store, the manifest signing path, the
  streaming verification, the group-sharing primitive. No parallel crypto
  implementation.
- **One serve path covers three use cases**: public, gated, and group differ
  by ~50 lines of policy code each. The chunk layer, manifest format, and
  storage are shared.
- **Sovereignty story is coherent**: IdentiKey owns the content, signs the
  manifest, signs the HEAD pointer. Hosts are semi-trusted (or fully untrusted
  in gated/group modes). No central authority for naming, content, or
  publishing.
- **IPNS analog without IPNS's problems**: the gateway resolves Iroh IDs
  directly, so "publish" is a local atomic operation. No DHT republish loop,
  no propagation delay.
- **Trust-minimized provenance for free**: OpenTimestamps anchoring gives every
  published snapshot a Bitcoin-backed "this content existed at this time"
  proof that anyone can verify against any Bitcoin node, without trusting the
  host, the gateway, or the IdentiKey holder. This is a publishing property the
  open web has structurally lacked.
