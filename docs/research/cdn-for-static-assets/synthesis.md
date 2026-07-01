# How should Mjolnir connect its served static applications, resources, and assets to a CDN?

## Executive Summary

A managed CDN is a sound fit for Mjolnir's static surface, but only for the *right* surface and only as a thin, swappable layer. The evidence (confirmed in code) shows Mjolnir's gateway is a transparent HTTP/1.1 byte-proxy that uses **DNS-01** ACME, so any pull-zone CDN can terminate HTTP/2-3 with clients and pull over HTTP/1.1 with **zero gateway changes and no risk to certificate issuance** [4]. The strongest fit on the team's own "middleman / lock-in-averse" axis is **Bunny.net** — CNAME-only DNS, bring-your-own / origin-keeps-its-own-cert, flat ~$0.01/GB ($10/mo at 1 TB, $50/mo at 5 TB), low exit cost [1]. The runner-up is **KeyCDN** (same low-lock-in shape, ~4x the cost) [1]. **Cloudflare** is the cheapest at scale ($0 bandwidth) and the only PaaS that actually fits the single-origin model, but it is the literal middleman the team flagged: Free/Pro requires full authoritative-DNS delegation and its edge always terminates client TLS — CNAME-only setup costs $200/mo (Business) [3]. Overall confidence is **medium-high**: the architecture-fit and low-lock-in verdicts are well-grounded, but several pricing figures (Fastly, Akamai, Netlify) are vendor-opaque or secondary-sourced and are flagged below.

---

## Spike Metadata (per-hypothesis)

```
H1  value/independent CDNs (Bunny.net, KeyCDN)
    confidence: medium-high | verification: web, primary pricing pages fetched
    version-pinned: prices ~June 2026 | spike-required: live HTTP/1.1-origin pull test vs mjolnir-gateway

H2  hyperscaler/enterprise CDNs (CloudFront, Fastly, GCP CDN, Azure Front Door, Akamai)
    confidence: medium | verification: web, mixed (official pages for CF/GCP/Azure; secondary/contract-only for Fastly/Akamai)
    version-pinned: prices ~June 2026 | spike-required: Fastly + Akamai sales quotes; Fastly/Azure HTTP/3 confirmation

H3  full-proxy PaaS/edge (Cloudflare, Netlify, Vercel)
    confidence: medium-high | verification: web, primary docs/ToS for CF & Vercel; Netlify pricing secondary
    version-pinned: CF ToS "Last Updated June 02 2026"; prices ~June 2026 | spike-required: Netlify true overage rate ($0.13 vs $0.55/GB unresolved)

H4 (+H5,+H9)  Mjolnir origin architecture fit
    confidence: high | verification: codebase, file:line citations
    version-pinned: current main | spike-required: production traffic geography + asset/SSR byte ratio; build CDN-purge-on-publish hook for Sites HTML

H6  contrarian: no managed CDN / self-host
    confidence: medium | verification: web + codebase; cost figures secondary-sourced
    version-pinned: prices ~June 2026 | spike-required: direct fetch of Vultr/BuyVM/Hetzner pricing before any budget model
```
(H5 signed-site caching hazards and H9 SSR-over-Iroh were folded into H4 per the decomposition cuts [6]; H7/H8 were folded into the shared rubric columns.)

---

## Comparison Rubric Matrix

Rows = 10 vendors + self-host. Costs assume ~90% cacheable immutable assets, NA/EU-weighted traffic, ~100 KB mean object. Nuance is in the per-option trade-offs below.

| Option | Features (PoPs / H3 / compute / WAF / signed-URL) | Origin / pull-zone fit | DNS requirement | TLS / key custody | Cost @1 TB/mo | Cost @5 TB/mo | Lock-in verdict |
|---|---|---|---|---|---|---|---|
| **Bunny.net** | 119 PoPs; HTTP/3; Optimizer add-on; Bunny Shield WAF/DDoS free; signed URLs native; Perma-Cache + Origin Shield free | Pull-zone, ideal; HTTP/1.1 origin assumed-OK (unverified) | CNAME-only | BYO upload **or** auto-LE; origin keeps own LE cert | **~$10** (NA/EU) / $5 Volume | **~$50** / $25 Volume | **Low** (swappable CNAME) |
| **KeyCDN** | ~60+ PoPs; HTTP/3 (claimed, unconfirmed); image add-on; no bundled WAF; Secure Token | Pull-zone via Zone Alias; HTTP/1.1 origin assumed-OK | CNAME-only (via Zone Alias) | BYO upload (unencrypted key) or free LE | **~$40** | **~$200** | **Low** ($49 prepay friction) |
| **AWS CloudFront** | 600+ PoPs (+1,140 embedded); HTTP/3; CloudFront Functions + Lambda@Edge; AWS WAF/Shield; signed URLs | Custom origin first-class; HTTP/1.1→HTTP/3 confirmed | CNAME-only (cert via ACM us-east-1) | ACM-managed or import; **AWS holds edge key**; origin keeps own cert | **~$0** (1 TB free tier) | **~$380** | **Med** (AWS account/IAM gravity) |
| **Fastly** | ~100 Super-PoPs; H3 unconfirmed; Compute (Wasm); Next-Gen WAF; ~150 ms purge (fastest) | Custom origin default; shield legs both billed | CNAME-only | **Full BYO cert, no forced managed path** (best custody story) | **~$90–150** (opaque, est.) | **~$350–500** (opaque, est.) | **Low** (no account gravity) |
| **Google Cloud CDN** | Google edge (PoP count n/a); HTTP/3; Service Extensions (Preview); Cloud Armor WAF (extra); signed URLs | Custom origin OK but **requires standing up a GCP Load Balancer** | CNAME/A + DNS-auth CNAME | Google-managed or self-managed (BYO) | **~$107** (incl. $18 LB) | **~$461** | **Med-High** (mandatory LB resource) |
| **Azure Front Door (Std)** | 192 edge locs; H3 **unconfirmed**; Rules Engine (declarative); WAF (separate); ~20 min purge (degraded) | Custom-host origin OK | **CNAME + TXT** (DCV migration forced 2025-26) | Azure-managed or **BYOC**; not forced to MS | **~$129** (incl. $35 base) | **~$505** | **Med** (TXT friction, forced migrations) |
| **Akamai** | Largest network; Fast Purge <5 s; Cloud Wrapper/Site Shield; Kona WAF (licensed sep.) | Custom origin reverse-proxy, first-class | CNAME-only | CPS-managed; BYO-key unconfirmed | **contract-only, ~uneconomical** | **~$8k–25k** (5–20 TB tier) | **Low technical / High commercial** |
| **Cloudflare** | ~330 cities; HTTP/3 default; Workers; free unmetered WAF/DDoS; native token auth | **Only PaaS that fits** — reverse proxy in front of existing origin; edge sees plaintext | **Full NS delegation** (Free/Pro); CNAME-only = Business $200/mo | **Edge always terminates client TLS, holds key**; origin re-encrypt via Full-Strict | **$0** (ToS-compliant) | **$0** (ToS-compliant) | **Deep but shallowest of PaaS** (DNS custody) |
| **Netlify** | Build+host platform; Edge Functions; not a generic reverse proxy (26 s proxy-rewrite hack only) | **Poor** — would mean re-platforming the deploy target | CNAME or NS (not plan-gated) | Auto-LE, edge-terminated | **~$130–550** (rate unresolved) | **~$650–2,750** | **Deepest** (is the deploy target) |
| **Vercel** | Build+host; Edge Middleware; best for Next.js; **discourages reverse-proxy in front of it** | **Poor** — no supported "front external origin" pattern | CNAME/A or NS (not gated) | Auto, edge-terminated | **~$20** (1 TB incl.) | **~$620+** ($0.15/GB over 1 TB) | **Deepest** (is the deploy target) |
| **Self-host (no CDN)** | HTTP/2/3 at gateway + host-side immutable cache (free win); DIY 5-node BGP-anycast possible | Native — it *is* the origin; no extra hop | None (own DNS/registrar) | Own LE cert end-to-end (full sovereignty) | **~$0 incremental** (HTTP/2 only) / **~$75–150** (5-node anycast) | same (+ egress) | **None** (full control; DDoS + PoP-breadth ceiling) |

---

## Per-Option Trade-offs (with the "middleman" constraint called out)

**Bunny.net** — You gain the best price/lock-in ratio in the field: 119 PoPs, HTTP/3, free bundled WAF/DDoS (Bunny Shield), and Perma-Cache that suits Mjolnir's fingerprinted-immutable assets, for ~$10–50/mo at 1–5 TB [1]. *Middleman profile:* no DNS delegation (CNAME-only), BYO-cert or auto-LE while the origin keeps its own LE cert, no metered platform beyond per-GB bandwidth. The edge does terminate client TLS (structural to any TLS-terminating CDN, not Bunny-specific). Exit cost = re-point a CNAME. Caveat: HTTP/1.1-origin pull compatibility is architecturally near-certain but not documented — flag for a live test [1].

**KeyCDN** — Same low-lock-in shape as Bunny (CNAME via Zone Alias, full BYO-cert upload) but ~4x the cost ($0.04/GB NA/EU tier-1) and a $49 prepay-credit floor [1]. *Middleman profile:* identical to Bunny — no delegation, origin keeps its own cert, edge terminates TLS. Narrower product surface (no edge compute, no bundled WAF brand) means even less ecosystem to evaluate. It is the viable runner-up only if Bunny is disqualified for non-cost reasons.

**AWS CloudFront** — You gain a 600+ PoP network, true HTTP/1.1-origin→HTTP/3-edge translation, and a **perpetual 1 TB/mo free tier** that makes the ~1 TB case ~$0 [2]. *Middleman profile:* CNAME-only DNS, but the edge cert must live in ACM (us-east-1) and **AWS holds that private key** (ACM blocks export); the origin can still run its own LE cert on the pull leg. Deeper lock-in is AWS account/IAM gravity and non-portable edge-function code, not DNS/TLS. ~$380/mo at 5 TB.

**Fastly** — You gain the deepest operational feature (~150 ms global purge) and the **most accommodating TLS-key-custody story of all ten** — true BYO cert via Custom/Platform TLS with no forced managed path [2]. *Middleman profile:* CNAME-only, no cloud-account gravity, you keep your key. The cost is pricing opacity: a real $50/mo floor and **no published per-GB rate card** — the ~$90–500/mo figures are secondary-source estimates ($0.10/GB midpoint) and must be treated as directional, not quotable [2]. HTTP/3 support was not confirmed.

**Google Cloud CDN** — Reasonably priced (~$107–461/mo) with BYO-cert and CNAME-based DNS, but it is the one vendor that **cannot be provisioned without first standing up a full GCP Load Balancer** (a ~$18/mo baseline plus VPC/backend-service scaffolding) [2]. *Middleman profile:* DNS/TLS stay portable, but the LB requirement pulls you into the GCP resource model — the deepest *structural* coupling of the five hyperscalers. Edge compute is Preview-only; WAF (Cloud Armor) is a separate bill. No free tier.

**Azure Front Door (Standard)** — Mid-pack pricing (~$129–505/mo incl. $35 base), full custom-origin and BYOC support [2]. *Middleman profile:* requires **CNAME + a TXT validation record** (more friction than pure-CNAME vendors), and Microsoft has already forced a cert-validation-method migration (CNAME-DCV deprecated Aug 2025, hard Jan 2026 deadline) — a concrete example of a vendor unilaterally changing a mechanism you depend on. HTTP/3 unconfirmed; purge reportedly degraded to ~20 min.

**Akamai** — Deepest enterprise security/scale (Fast Purge <5 s, Site Shield, Cloud Wrapper), low *technical* lock-in (CNAME-only). *Middleman profile:* high *commercial* lock-in — contract-only pricing with no public rate card, multi-year terms, renewal price increases (a 2026 10% adjustment is live), and BYO-TLS-key support unconfirmed [2]. At Mjolnir's 1–5 TB/mo it is almost certainly **below the threshold where a contract is even accessible** (cited small/mid tier starts at 5 TB and $8k/mo) — the clearest "deepest features, least accessible economics" case.

**Cloudflare** — The only PaaS that architecturally fits Mjolnir (reverse proxy in front of an existing origin), with the strongest economics in the market: **unmetered/$0 bandwidth at any scale**, global anycast, HTTP/3, free WAF/DDoS, and native token auth that directly supports the signed-asset model [3]. *Middleman profile — this is the flagged concern made literal:* Free/Pro requires moving the zone's **authoritative nameservers to Cloudflare** (full DNS custody, not a CNAME), and the edge **always terminates client TLS and sees plaintext** (true even with an uploaded custom cert, since the key must sit on the edge). CNAME-only "partial" setup that avoids delegation is gated to **Business ($200/mo per zone)**. The old §2.8 "must be mostly HTML" rule was removed in 2023 and replaced by a clause requiring Cloudflare-owned storage (R2/Stream/Images) to serve "video or a disproportionate percentage of … large files" — very likely fine for Mjolnir's small fingerprinted text/JS/CSS/image profile, but it is a *named* trigger, not a hypothetical [3]. Lock-in is swappable in principle (re-point NS) but loses all Cloudflare features at once.

**Netlify** — A polished build+CDN+functions platform, but it **assumes Netlify is your hosting platform**, not a layer in front of someone else's origin [3]. Its only path to front Mjolnir's self-hosted origin is the `/*` proxy-rewrite — built for API path-proxying, capped at a 26 s timeout, one hop, with documented full-site fragility. *Middleman profile:* CNAME or NS (not plan-gated), auto-LE edge-terminated. Adopting it means re-platforming the deploy target (defeats self-hosting) — deepest lock-in tier. Bandwidth is credit-metered with two **unreconciled** secondary-source rates ($0.13 vs $0.55/GB), yielding a wide ~$130–2,750/mo range [3].

**Vercel** — The most refined SSR/edge DX, but the least compatible with Mjolnir's model: its docs **explicitly discourage a reverse proxy in front of it**, and it offers no first-class "front an external origin" pattern — it wants to *be* the origin [3]. *Middleman profile:* CNAME/A or NS (not gated), auto edge-terminated TLS. Pro includes 1 TB then $0.15/GB (~$20 at 1 TB, ~$620+ at 5 TB). Best-tuned for Next.js, not Mjolnir's SvelteKit. Deepest lock-in tier alongside Netlify.

**Self-host (no managed CDN)** — You gain full sovereignty over DNS, registrar, and origin certs, and zero middleman. Enabling **HTTP/2 (ideally HTTP/3) at the gateway plus a host-side immutable-asset cache is a free, unconditional win** that removes the connection-multiplexing tax on zine's ~10-parallel `_app/immutable/*` waterfall — and should be done regardless of any CDN decision [5][4]. *The ceiling:* none of this shortens geographic RTT (Frankfurt→Asia ~400–800 ms), and a real BGP-anycast fleet stops being free — ~$75–150/mo in raw infra/session fees for 5 nodes, plus standing ops burden (per-node cert sync, cross-node purge, BGP/ASN management) that a $5–10/mo Bunny pull zone replaces outright [5]. Self-host also cannot match a managed CDN's DDoS absorption (hundreds of Tbps) or PoP breadth (300+ cities vs ~5 nodes).

---

## Overall Cost Ranking

**At ~1 TB/mo (≈90% cacheable, NA/EU):**
1. Cloudflare Free — **$0** (if ToS-compliant; bandwidth unmetered) [3]
2. CloudFront — **~$0** (perpetual 1 TB free tier) [2]
3. Bunny.net — **$5** (Volume) / **$10** (Standard NA/EU) [1]
4. Vercel Pro — **~$20** (within 1 TB included) [3]
5. KeyCDN — **$40** [1]
6. Self-host — **~$0 incremental** (HTTP/2 only) to **~$75–150** (5-node anycast) [5]
7. Fastly — **~$90–150** (opaque estimate) [2]
8. Google Cloud CDN — **~$107** [2]
9. Azure Front Door — **~$129** [2]
10. Netlify — **~$130–550** (rate unresolved) [3]
11. Akamai — **contract-only; effectively inaccessible/uneconomical** [2]

**At ~5 TB/mo:**
1. Cloudflare Free — **$0** [3]
2. Bunny.net — **$25** (Volume) / **$50** (Standard NA/EU) [1]
3. KeyCDN — **$200** [1]
4. Fastly — **~$350–500** (opaque estimate) [2]
5. CloudFront — **~$380** [2]
6. Google Cloud CDN — **~$461** [2]
7. Azure Front Door — **~$505** [2]
8. Vercel — **~$620+** [3]
9. Netlify — **~$650–2,750** (rate unresolved) [3]
10. Self-host — **~$75–150 + multi-region egress** [5]
11. Akamai — **~$8k–25k** (5–20 TB enterprise tier) [2]

**Free-tier ToS catches:** Cloudflare's bandwidth is unmetered but conditioned on the post-2023 large-file clause (Cloudflare-owned storage required for "disproportionate" large files / video) — the modern successor to the old §2.8 "mostly HTML" rule [3]. CloudFront's 1 TB free tier is perpetual, not a 12-month trial [2]. Vercel Hobby's 100 GB is hard-capped with no purchasable overage [3]. **Unverified numbers flagged:** Fastly (no public rate card — all figures secondary), Akamai (contract-only), Netlify ($0.13/GB vs $0.55/GB unreconciled). Treat these three as directional pending a sales quote / live dashboard check.

---

## Recommendation for Mjolnir

**1. Sequence the free win first.** Enable HTTP/2 (ideally HTTP/3) at `mjolnir-gateway` and add a host-side cache for `_app/immutable/*` and other content-hashed, long-`max-age` assets so they never reach the VM. This is free, removes the measured multiplexing bottleneck, and matches the gateway plan's own stated order ("HTTP/2 → host-side cache → real CDN last") [5][4]. Do this regardless of the CDN choice.

**2. Put only the right surface behind a CDN.** Front the **fingerprinted/hash-addressed static assets and (once a real HTTP transport exists for `Server.serve/3`) content-addressed signed-site blobs** — both are immutable by construction and verified-once-at-write, making them ideal cache objects [4]. **Do not** CDN-front the SSR-over-Iroh path: it is a live, mutable app process where a CDN hop adds latency with zero cache benefit (H9 marginal case confirmed) [4]. For **non-fingerprinted Sites HTML pages**, treat like SSR (short/zero TTL) until a publish-time CDN-purge hook is built into `Publisher` — this is the one genuinely new piece of work, because external `/about.html`-style paths resolve through a mutable HEAD pointer and a URL-keyed cache will serve a stale HEAD after publish [4].

**3. Primary pick: Bunny.net.** Best fit for the team's lock-in-aversion: CNAME-only, BYO/auto cert with the origin keeping its own LE cert, ~$10–50/mo, free WAF/DDoS, Perma-Cache for immutable assets [1].

**4. Runner-up: KeyCDN** (same low-lock-in shape, ~4x cost) — or **Fastly** if BYO-key custody and instant purge are weighted heavily and the team will get a sales quote [1][2].

**5. "If you accept the middleman": Cloudflare Free.** Unbeatable at $0 and the only PaaS that fits a single self-hosted origin — but only if the team accepts full NS delegation and edge TLS termination (it sees plaintext), and stays within the large-file ToS clause. The $200/mo Business plan buys back CNAME-only (no delegation) if that one constraint is the dealbreaker [3].

**Migration / integration notes:**
- **CNAME indirection:** point an asset subdomain (e.g. `cdn.<domain>`) at the CDN's pull-zone hostname; keep registrar + authoritative DNS in-house (true for Bunny/KeyCDN/CloudFront/Fastly; not for Cloudflare Free/Pro) [1][3].
- **Keep the origin LE cert:** the gateway's existing per-domain Let's Encrypt cert simply becomes the edge↔origin cert; configure the CDN's origin-pull to HTTPS with cert verification [1][4].
- **ACME caveat (good news):** Mjolnir uses **DNS-01** (Cloudflare TXT records), not HTTP-01, so a CDN intercepting client HTTP traffic cannot break issuance or renewal — the http-01-interception concern does not apply [4].
- **SNI≡Host:** the gateway enforces SNI = Host and returns 421 on mismatch; ensure the CDN's origin-pull SNI matches Host (default for Bunny/Cloudflare/Fastly/CloudFront) [4].
- **Cache-key / stale-head handling:** cache only hash-addressed paths (no purge needed); for non-fingerprinted Sites HTML use short/zero TTL or build the purge-on-publish hook [4].
- **Optional origin lockdown:** no IP-allowlist exists at the gateway today; CDN-only origin access (if desired) must be enforced at the host firewall via Forge, not in gateway code [4].

---

## Open Questions

1. **Production traffic geography + asset/SSR byte ratio** — not derivable from code; decides how much geo-latency a CDN actually buys and how strong the contrarian position is [4][5].
2. **Live HTTP/1.1-origin pull test** against `mjolnir-gateway` for the chosen CDN — architecturally near-certain but undocumented for Bunny/KeyCDN [1].
3. **Fastly and Akamai real pricing** — both require sales quotes; current figures are secondary/contract-only [2].
4. **Netlify true overage rate** — $0.13/GB vs $0.55/GB unresolved (~4x swing) [3].
5. **HTTP/3 confirmation** for Fastly, Azure Front Door, and KeyCDN — claimed/unconfirmed [1][2].
6. **Build the CDN-purge-on-publish hook** for Sites HTML before fronting non-fingerprinted pages [4].
7. **DDoS threat model** — is it a real concern for a small self-hosted platform, or imported from generic CDN best-practice framing? [5]

---

## Methodology

Five hypotheses investigated in parallel (H1 value CDNs, H2 hyperscalers, H3 full-proxy PaaS, H4 origin-architecture-fit, H6 contrarian), covering 10 vendors + the self-host option against a shared 7-column rubric [6]. Investigation types: web research with primary-source pricing/docs fetches (H1–H3, H6) and codebase grounding with file:line citations (H4, H6). H5 (signed-site caching hazards) and H9 (SSR/Iroh) were folded into H4; H7 (TLS custody) and H8 (TCO) were folded into rubric columns [6]. Depth reached: vendor-level rubric completion plus code-grounded architecture verification; no live integration test was performed (flagged as the primary spike).

---

## References

[1] `hypotheses/h1-value-cdns/findings.md` §Evidence/§Sources — Bunny.net & KeyCDN. "Bunny: NA/EU $0.01/GB, Volume $0.005/GB, $1/mo min, 119 PoPs, HTTP/3, Bunny Shield free, CNAME-only, BYO-cert upload"; "KeyCDN: $0.04/GB NA/EU tier-1, $49 prepay, ~60+ PoPs, Zone-Alias CNAME". Embedded primary sources: bunny.net/pricing/cdn/, bunny.net/cdn/features/, keycdn.com/pricing, keycdn.com/support/create-a-zone-alias.
[2] `hypotheses/h2-hyperscaler-cdns/findings.md` §per-vendor/§Sources — CloudFront (1 TB free tier, $0.085/GB, ACM holds key, CNAME-only), Fastly ($50/mo floor, no public rate card, full BYO-cert, ~150 ms purge), Google Cloud CDN ($0.08/GiB + mandatory LB ~$18/mo), Azure Front Door ($35 base + $0.083/GB, CNAME+TXT, BYOC), Akamai (contract-only, ~$8k–25k at 5–20 TB). Embedded primary sources: aws.amazon.com/cloudfront/pricing/, fastly.com/pricing, cloud.google.com/cdn/pricing, azure.microsoft.com/pricing/details/frontdoor/.
[3] `hypotheses/h3-fullproxy-paas/findings.md` §Evidence/§Sources — Cloudflare (Free/Pro = full NS delegation, CNAME-only = Business $200/mo, edge terminates TLS, unmetered bandwidth, post-2023 large-file ToS clause, "Last Updated June 02 2026"), Netlify (build-host, 26 s proxy hack, credit pricing $0.13 vs $0.55/GB unreconciled), Vercel ("we do not recommend a reverse proxy in front", 1 TB incl. then $0.15/GB). Embedded primary sources: developers.cloudflare.com/dns/zone-setups/, cloudflare.com/service-specific-terms-application-services/, vercel.com/docs/security/reverse-proxy, vercel.com/pricing, docs.netlify.com/manage/routing/redirects/rewrites-proxies/.
[4] `hypotheses/h4-origin-architecture-fit/findings.md` §Evidence — "gateway is transparent HTTP/1.1 byte-proxy (`main.rs:765-802`, `714-749`)"; "SNI≡Host 421 (`main.rs:846-856`)"; "DNS-01 ACME not HTTP-01 (`acme.rs:227,265,457,476`)"; "chunks verified-on-write only (`storage/local.ex:69-77`)"; "external paths resolve through mutable HEAD — stale-head hazard (`server.ex:51-55`)"; "SSR-over-Iroh = wrong CDN target".
[5] `hypotheses/h6-contrarian-no-cdn/findings.md` §Evidence — "HTTP/2/3 + host-side cache = free win, fixes multiplexing not geo-RTT"; "5-node BGP-anycast ~$75–150/mo + ops burden (cert sync, cross-node purge, BGP)"; "Bunny $0.005–0.01/GB beats DIY on total cost"; "self-host can't match Tbps DDoS / 300+ PoPs". Embedded sources: buyvm.net/anycast-vps/, bunny.net/pricing/cdn/, wondernetwork.com/pings, docs.varnish-software.com/book/operations/tls/.
[6] `decomposition.md` §Shared Rubric/§Selected Hypotheses/§Cuts — rubric columns, 5-branch partition, H5/H7/H8/H9 fold-in rationale.

---

## Verification

- **Citations checked**: 6/6 references resolve to real findings documents (each Read in full); every matrix cell and cost figure traces to [1]–[5], and each findings file carries its own embedded primary/secondary URLs.
- **Hypotheses covered**: 5/5 explored (H1, H2, H3, H4+H5+H9, H6). All 10 vendors + self-host appear in the matrix. H5/H9 folded into H4 and addressed (signed-site caching, SSR-over-Iroh). H7/H8 folded into rubric columns and addressed (TLS custody, cost).
- **Unsupported claims**: none. All factual claims carry a citation.
- **Issues found / warnings**:
  - Fastly cost ($90–500/mo) is a secondary-source estimate ($0.10/GB midpoint) — Fastly publishes no per-GB rate card [2].
  - Akamai cost is contract-only; 1–5 TB figures are unverifiable and likely below its accessible floor [2].
  - Netlify overage rate is unreconciled ($0.13 vs $0.55/GB), a ~4x swing on its cost rows [3].
  - HTTP/3 unconfirmed for Fastly, Azure Front Door, and KeyCDN [1][2].
  - HTTP/1.1-origin pull is documented-by-architecture, not vendor-confirmed, for Bunny/KeyCDN [1].
  - Cloudflare per-plan dollar figures and "unmetered" claim corroborated via secondary aggregators, not a direct cloudflare.com/plans fetch [3].
- **Confidence calibration**: Executive summary states **medium-high** overall, consistent with the strongest branch (H4, high) being tempered by the opaque-pricing branches (H2 Fastly/Akamai, H3 Netlify, all medium). No branch claims "high" on the contested pricing.
- **Verification status**: **PASS_WITH_WARNINGS** (all warnings are vendor-side pricing opacity / unconfirmed feature flags, explicitly disclosed; no fabricated citations, no silent hypothesis drops, no false consensus).
