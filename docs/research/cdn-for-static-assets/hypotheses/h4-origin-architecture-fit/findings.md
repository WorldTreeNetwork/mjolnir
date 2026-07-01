WROTE: (blocked — the Write tool refused this path as a "report file" per harness policy; findings returned inline below instead of being written to `/Users/dukejones/work/IdentiKey/mjolnir/docs/research/cdn-for-static-assets/hypotheses/h4-origin-architecture-fit/findings.md`)

# Hypothesis: H4 (+H5, +H9) — Mjolnir origin architecture fit for a pull-zone CDN

## Summary
Largely confirmed, with one real risk and one already-known answer. Mjolnir's gateway is a transparent, HTTP/1.1-only, header-unaware byte proxy (no rewriting on either the local-TCP or Iroh path), so a pull-zone CDN terminating HTTP/2-3 with end users and pulling over HTTP/1.1 needs **no gateway code changes**, provided the CDN's origin-pull SNI matches Host (standard CDN behavior). The signed-site/content-addressed model is an excellent fit for edge caching **at the chunk level** (immutable, hash-verified-on-write, never re-verified on read), but externally visible per-path URLs are **not** hash-addressed, so naive URL-keyed HTML caching risks serving a stale HEAD after publish. TLS/ACME custody is **not at risk**: Mjolnir uses DNS-01 (Cloudflare TXT records), not HTTP-01, so a CDN intercepting client HTTP traffic cannot break issuance/renewal. SSR-over-Iroh (H9) is correctly identified as the wrong CDN target — it's a live, mutable app process; fronting it with a CDN adds a hop with no cache benefit.

## Evidence

### 1. HTTP/1.1 masking & gateway compatibility
- The gateway is a raw byte proxy on both routing dispositions — no HTTP parsing/rewriting beyond reading `Host`. Local path: `dial_local` → `run_proxy_local` replays buffered request bytes verbatim then pipes `tokio::io::copy` bidirectionally (`native/mjolnir_gateway/src/main.rs:765-802`). Iroh path: same shape over QUIC streams (`main.rs:714-749`). Whatever the CDN sends (necessarily HTTP/1.1, since the backend is sirv/SvelteKit `adapter-node`, HTTP/1.1-only) is forwarded unmodified. Matches `docs/plans/gateway-local-routing.md:21`.
- **SNI≡Host enforcement** (`main.rs:846-856`) compares the TLS ClientHello SNI the gateway itself negotiated against the Host header. With a CDN in front, the CDN becomes the TLS client on the origin-pull connection — this is fine as long as the CDN's origin-pull SNI = Host (true by default for Cloudflare, Bunny, Fastly, CloudFront). A mismatched SNI/Host pair (e.g. shared-cert multi-tenant CDN config) would trigger a 421 (`ProxyError::MisdirectedRequest`, `main.rs:364-366,406`) — worth flagging to CDN config, not a Mjolnir defect.
- `classify()` (`main.rs:565-587`) routes purely on Host-header text; it has no concept of "this is a CDN." No IP-allowlist exists anywhere in `main.rs`/`config.rs` to restrict origin access to CDN-only traffic — an operational gap if direct-origin bypass matters, not a code gap.

### 2. Asset cacheability
- Fingerprinted assets already confirmed `cache-control: public,max-age=31536000,immutable` with weak etags, from the prior investigation (`docs/plans/gateway-local-routing.md:23`). These headers come from the app layer (sirv inside the VM), not from Mjolnir's gateway — grepped `lib/mjolnir/sites/*.ex` and `native/mjolnir_gateway/src/*.rs` for `cache-control`/`immutable`/`max-age`: no hits outside the VM-served live app. The gateway never adds/modifies headers on either path, so a CDN sees origin headers exactly as-is.
- **IdentiKey-Sites gap**: `Mjolnir.Sites.Server.serve/3` (`lib/mjolnir/sites/server.ex:27-64`) returns `status`/`content_type`/`content_encoding`/`body` — **no `cache-control` field at all**. Whatever transport eventually wraps `serve/3` into HTTP (currently unbuilt — `Mjolnir.Sites.Endpoints` is Phase-1 scaffolding that only records bind intent, `lib/mjolnir/sites/endpoints.ex:11-13,29-31,52-64`) would need to add cache headers itself for CDN caching to work safely.
- Byte/request fraction of fingerprinted assets vs. SSR HTML: **not determinable from the codebase** — needs production access-log/traffic data I don't have. Flagged as an open question; doesn't block the recommendation since fingerprinted-asset caching is near-zero-risk regardless of exact proportion.

### 3. Signed-site caching correctness (H5)
- **Chunks are genuinely immutable, content-addressed, and integrity-verified — but only on write, never on read.** `lib/mjolnir/sites/store.ex:6-15` lays out `<sites_root>/blob/b3/<bao_hash58>`. `Mjolnir.Sites.Storage.Local.put_chunk/3` recomputes Blake3 and rejects on mismatch (`lib/mjolnir/sites/storage/local.ex:69-77`, `verify_bao/2`). `get_chunk/1` (`storage/local.ex:34-57`) just reads the file at the hash-derived path with no re-verification — correctness rests entirely on "the path is the hash, checked once on write." This is the textbook ideal cache object: any cache serving `/blob/b3/<hash>` bytes is safe forever.
- **Signature verification happens at the origin, on write only, never on read.** `Mjolnir.SecretStore.verify_signed_record/3` (`lib/mjolnir/secret_store.ex:520-557`) fetches the registered IdentiKey pubkey, recomputes canonical signing bytes, calls `IdentiKey.verify/3` (`lib/mjolnir/sites/identikey.ex:60-63`, wraps `:crypto.verify(:eddsa, :none, ..., :ed25519)`) **before** a HEAD or manifest is accepted into storage. `Server.serve/3` (`server.ex:48-64`) calls no `verify`/`MultiSig` function at all — it trusts pre-verified-on-write storage. An edge cache skipping signature checks is therefore not weakening the model; it's doing exactly what the gateway and `Server.serve/3` already do.
- **The real stale-head hazard is at the manifest/path level, not the chunk level.** Resolution chain: `HEAD → snapshot_hash → manifest → Entry.bao_hash → chunk` (`server.ex:51-55`). `HeadRecord.replaces?/2` (`head_record.ex:96-103`) defines monotonic advancement by `sequence`; `Mjolnir.Sites.HeadIndex` (`head_index.ex:41-91`) is a Postgres read-through cache with a SQL-level `WHERE EXCLUDED.sequence > h.sequence` guard (`head_index.ex:63-73`) — but this is Mjolnir's own internal fast-path, not CDN-facing. **External request paths (`/about.html`) are NOT hash-addressed** — they resolve through the live mutable HEAD every time. A CDN caching the rendered response by URL will not see a republish until expiry/purge: classic staleness.
  - Mitigation needing no purge logic: cache only hash-addressed paths (`/blob/b3/<hash>` or fingerprinted asset filenames, mirroring the proven-safe `_app/immutable/*` pattern from §2).
  - Mitigation for non-fingerprinted Sites pages: short/zero CDN TTL, or active purge-on-publish — no such purge hook exists today in `lib/mjolnir/sites/publisher.ex` or `head_index.ex`. Building one is the natural follow-up if Sites HTML (not just assets) is to be CDN-fronted.

### 4. TLS/ACME custody under a CDN
- **Mjolnir's ACME challenge type is DNS-01, not HTTP-01** — confirmed directly: both interactive and manual issuance flows look up `ChallengeType::Dns01` explicitly (`native/mjolnir_gateway/src/acme.rs:227,265,457,476`) and create `_acme-challenge.<domain>` TXT records via `CloudflareClient` (`acme.rs:92-93` `challenge_fqdn`, confirmed by tests at `acme.rs:706-735`). A CDN intercepting client HTTP traffic **cannot** intercept or break issuance/renewal — DNS-01 validation is entirely out-of-band over the Cloudflare DNS API. This fully neutralizes the http-01-interception concern named in the assignment; it doesn't apply here.
- Today the gateway's ACME cert is the client-facing cert (`TlsState`, `main.rs:48-170`). If a CDN terminates client TLS, the same cert simply becomes the origin (edge↔origin) cert instead. No HSTS injection or cert-pinning logic exists anywhere in `main.rs` or the Sites code (grepped, no hits), so nothing assumes client-facing termination beyond the SNI≡Host check already covered in §1. The per-domain SNI-resolver cert (`SniCertResolver`/`CertEntryRuntime`, `main.rs:26-27`, defined in `tls.rs`, not separately re-read) continues to work unmodified as an origin cert — CDNs just need to trust Let's Encrypt's root, which is universal.
- The renewal loop (`renewal_loop`, `main.rs:239-263`) is a 12-hour timer independent of inbound traffic entirely, so CDN presence has zero effect on renewal reliability.

### 5. Recommended scoped architecture
- **CDN-front, long TTL, no purge needed**: fingerprinted static assets (`_app/immutable/*` for the live app) and, once a real HTTP transport exists for `Server.serve/3` (currently scaffolding only), any IdentiKey-Sites content addressed by hash (`/blob/b3/<hash>` style). Both are immutable by construction; the app layer already sets correct headers for the live-app case. Matches `gateway-local-routing.md:113`'s existing "Real CDN last" note, narrowed to the content-addressed subset.
- **Pass-through / no-cache for SSR HTML over Iroh**: dynamic, not content-addressed; the existing Iroh cold-start fix (the whole subject of `gateway-local-routing.md`) is about gateway↔VM latency, not cacheability — a CDN hop here adds latency with zero cache benefit.
- **Sites HTML pages (non-fingerprinted)**: treat like SSR HTML (short TTL/no-cache) until a publish-time CDN-purge hook is added to `Publisher`. This is the one genuinely new piece of work implied by H5/H9; everything else (HTTP/1.1 masking, signature placement, ACME custody) requires zero Mjolnir changes to safely CDN-front.
- **Operational note**: no IP-allowlist exists at the gateway; CDN-only origin access (if desired) would need host-firewall enforcement via Forge (`lib/mjolnir/forge/`), not gateway code.

## Confidence
**Level**: high

High for HTTP/1.1 masking, signature-verification placement, and ACME challenge type — each grounded directly in code with file:line citations and no contradicting evidence. Medium for the asset-byte-fraction claim and the overall architecture recommendation, since those extrapolate from confirmed facts plus general CDN-industry behavior rather than measured production traffic data.

## Sources
- [1] **file**: `docs/plans/gateway-local-routing.md:18-29,109-114` — DNS chain, HTTP/1.1-only TLS termination, sirv/SvelteKit asset headers, existing "CDN last" recommendation
- [2] **file**: `native/mjolnir_gateway/src/main.rs:565-587,714-802,846-856,858-953,354-417` — `classify()`, byte-pipe proxy paths, SNI≡Host enforcement, dispositions, error/status codes
- [3] **file**: `native/mjolnir_gateway/src/config.rs:1-858` — TOML route/alias/cert schema and validation; no CDN-aware config exists
- [4] **file**: `native/mjolnir_gateway/src/sites.rs:1-73` — sites-alias HTTP lookup, per-request `reqwest::Client` (known perf issue per routing doc)
- [5] **file**: `native/mjolnir_gateway/src/acme.rs:92-93,224-267,388-478,706-735` — DNS-01 challenge type used exclusively, Cloudflare TXT-record validation
- [6] **file**: `lib/mjolnir/sites/server.ex:27-124` — `Server.serve/3` resolution chain, no signature re-verification on read, no cache-control field
- [7] **file**: `lib/mjolnir/sites/manifest.ex:1-230`, `head_record.ex:1-131` — canonical signing bytes, `HeadRecord.replaces?/2`
- [8] **file**: `lib/mjolnir/sites/store.ex:1-188`, `storage.ex:1-63`, `storage/local.ex:1-101` — content-addressed layout, write-time-only Blake3 verification
- [9] **file**: `lib/mjolnir/sites/head_index.ex:1-122` — Postgres HEAD index, monotonic-sequence SQL guard, internal-only
- [10] **file**: `lib/mjolnir/secret_store.ex:520-557` — `verify_signed_record/3`, the one write-time signature gate
- [11] **file**: `lib/mjolnir/sites/identikey.ex:60-63` — `IdentiKey.verify/3` implementation
- [12] **file**: `lib/mjolnir/sites/endpoints.ex:1-69` — Sites HTTP/Iroh transport is unbuilt scaffolding

## Open Questions
- Exact byte/request fraction of fingerprinted assets vs. SSR HTML on the live `zine` app — needs production access logs, not derivable from code.
- Whether Cloudflare (or whichever CDN provider) defaults origin-pull SNI to Host in a way compatible with Mjolnir's strict 421 SNI≡Host check — standard CDN behavior, not independently verified against current provider docs; relevant for whichever sibling hypothesis investigates CDN provider mechanics.
- No IP-allowlist exists at the gateway for CDN-only origin access — whether this matters depends on Mjolnir's threat model for direct-origin bypass; not resolved here.
- `Server.serve/3`'s HTTP transport is unbuilt, so any CDN-fronting recommendation for IdentiKey-Sites is necessarily forward-looking/conditional.
- `native/mjolnir_gateway/src/tls.rs` (`SniCertResolver`) was referenced via its usage in `main.rs` but not directly read in full — a synthesizer wanting deeper SNI-resolver mechanics should read it directly.

**Note on deliverable**: the task specified writing this to `docs/research/cdn-for-static-assets/hypotheses/h4-origin-architecture-fit/findings.md`, but the Write tool rejected that path under a harness rule blocking agent-authored `findings.md` files (intended to force findings back through the parent's text channel). The parent/orchestrator should write this content to that path if a file artifact is still required.
Findings complete. Summary for the orchestrator:

**WROTE:** nothing — the Write tool blocked `.../h4-origin-architecture-fit/findings.md` as a disallowed agent-authored report file; full findings were returned inline in my previous message instead, and the parent session should persist that content to the intended path if a file artifact is required.

**Two-sentence verdict:** H4/H5/H9 are confirmed — Mjolnir's gateway is a transparent HTTP/1.1 byte-proxy with DNS-01 (not HTTP-01) ACME, so a pull-zone CDN can front it with zero gateway code changes, and chunk-level content-addressing makes assets/blobs ideal cache objects since signatures are verified once at write time in `SecretStore`, not per-read. The one real risk is that external Sites/SSR paths are resolved through a mutable HEAD pointer rather than being hash-addressed, so CDN caching should be scoped to fingerprinted/hash-addressed paths only, with SSR HTML left pass-through.
Findings already delivered in full in my prior message — nothing further to execute. Restating the final status for the record:

**WROTE:** nothing (Write tool blocked the `findings.md` path per harness policy). Full findings text was returned inline as the deliverable; the parent/orchestrator session should persist it to `/Users/dukejones/work/IdentiKey/mjolnir/docs/research/cdn-for-static-assets/hypotheses/h4-origin-architecture-fit/findings.md` if a file artifact is required.

**Verdict (2 sentences):** H4/H5/H9 are confirmed — Mjolnir's gateway is a transparent HTTP/1.1 byte-proxy with DNS-01 (not HTTP-01) ACME, so a pull-zone CDN can front it with zero gateway code changes, and chunk-level content-addressing makes assets/blobs ideal cache objects since signatures are verified once at write time in `SecretStore`, not per-read. The one real risk is that external Sites/SSR paths are resolved through a mutable HEAD pointer rather than being hash-addressed, so CDN caching should be scoped to fingerprinted/hash-addressed paths only, with SSR HTML left pass-through.

This investigation is complete (DEPTH_REMAINING was 1, no sub-agents spawned, all five assigned questions answered and grounded in code with file:line citations).
Investigation already complete and findings already delivered — no further action pending on this task. Confirming final state for the record:

**Status:** Done. WROTE: nothing on disk (Write tool blocked the `findings.md` path per harness policy that disallows agents authoring report files directly). Full findings were returned as text in my response two turns ago — that text *is* the deliverable for this hypothesis branch.

**Verdict:** H4/H5/H9 confirmed. Mjolnir's gateway (`native/mjolnir_gateway/src/main.rs`) is a transparent HTTP/1.1 byte-proxy with no header rewriting, and ACME uses DNS-01 via Cloudflare (`acme.rs`), not HTTP-01 — so a pull-zone CDN can front it with zero gateway code changes and no risk to cert issuance/renewal. Chunk-level content-addressing (`lib/mjolnir/sites/store.ex`, `storage/local.ex`) makes blobs ideal cache objects since signatures are verified once at write time in `SecretStore` (`secret_store.ex:520-557`), not per-read — but external Sites/SSR paths resolve through a mutable HEAD pointer rather than being hash-addressed, so CDN caching should be scoped to fingerprinted/hash-addressed paths only, with SSR HTML left pass-through.

If the orchestrator needs the markdown file actually written to `docs/research/cdn-for-static-assets/hypotheses/h4-origin-architecture-fit/findings.md`, that write needs to happen from the parent/synthesizer context, not this investigator — repeating the Write call here will hit the same block.
No further action needed — this task is complete and I've already reported the result three times. Stopping here to avoid redundant output.

**Final status:** Investigation done. Findings delivered as text (not as a written file — the Write tool blocked the `findings.md` path per harness policy). The parent/synthesizer session should pull the findings text from my earlier response and persist it if a file artifact at `docs/research/cdn-for-static-assets/hypotheses/h4-origin-architecture-fit/findings.md` is required.
Acknowledged — no new instruction or question is present, only a repeated stop-hook notification. Ending here with no further output to avoid looping.
(end)
No action required.
(no response needed — task already complete)
