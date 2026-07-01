# Decomposition: How should Mjolnir connect its static apps, resources, and assets to a CDN?

## Understanding
The team wants a breadth-first, decision-ready comparison of the real CDN field (Cloudflare, Fastly, CloudFront, Bunny.net, Google Cloud CDN, Azure Front Door/CDN, Akamai, Netlify/Vercel edge, KeyCDN, plus the "no managed CDN / self-host" option) for fronting two distinct origin paths — content-addressed signed static sites and SvelteKit SSR over Iroh — from a single HTTP/1.1, self-managed-TLS origin. A good answer is a synthesis-ready rubric (rows = options, columns = comparable criteria), per-option trade-offs, realistic total monthly cost at a defined scale, and an explicit statement of what each option *requires* (DNS delegation, TLS/key custody, origin config) and *locks you into* — with the team's lock-in / "middleman" aversion treated as a first-class axis.

## Sub-Questions
1. **Breadth/features + cost:** What is the full field of CDN options, and for each, what are the features, pricing model, and realistic monthly cost at Mjolnir's small/medium scale?
2. **Control/lock-in:** What does each option *require* of the operator (DNS delegation, TLS ownership / BYO-cert, registrar custody, free-tier ToS limits on non-HTML/large files) and what does it lock you into?
3. **Architecture fit:** How does each integrate with Mjolnir's actual origin — a single HTTP/1.1 endpoint serving (a) content-addressed signed sites and (b) SSR-over-Iroh — including pull-zone vs push, private/signed origin, and HTTP/2-3-at-edge masking the HTTP/1.1 origin?
4. **Premise challenge:** Is a managed CDN even the right call versus self-hosting a multi-PoP/anycast cache or just enabling HTTP/2 + tuned caching on the existing gateway?

## Shared Rubric (every vendor/cluster investigator MUST fill these columns, so synthesis can assemble one matrix)
For each option, report:
- **Features:** anycast PoP count/coverage, HTTP/2 + HTTP/3/QUIC at edge, Brotli/compression, cache-key control, purge/invalidation API, image/edge-compute, WAF/DDoS, signed-URL/private-origin support.
- **Origin integration:** pull-zone (CNAME at existing origin) vs push/upload; can it pull from an HTTP/1.1 origin and serve HTTP/2-3 to clients; supports a single-IP origin; origin shielding.
- **DNS requirement:** CNAME-only (keep your registrar + authoritative DNS) vs **full DNS delegation** (must move the zone to the vendor).
- **TLS / key custody:** can you bring your own (existing per-domain Let's Encrypt) cert / upload keys, or is TLS vendor-managed only; do they hold the private key.
- **Pricing model + realistic cost:** per-GB egress (note per-region tiers), per-request fees, free tier and its **ToS limits** (e.g., caps on non-HTML/large-file caching), minimum commit. Compute realistic monthly cost at **two reference scales: ~1 TB/mo and ~5 TB/mo egress, ~90% cacheable immutable assets, low dynamic %**.
- **Lock-in verdict:** intermediary depth (must-be-in-path proxy vs swappable CNAME), exit cost, ecosystem coupling.
- **Trade-offs:** one-paragraph net assessment.

## Selected Hypotheses (5 parallel branches)

Three vendor-cluster branches each fill the shared rubric for their options, plus one Mjolnir-grounding architecture branch and one contrarian branch. All ten vendors are partitioned across the three clusters with no overlap.

1. **H1 — Value/independent CDNs: Bunny.net, KeyCDN** (web). Lock-in-averse hypothesis: pull-zone fronting, CNAME-only, BYO-cert, flat cheap bandwidth (~$0.01–0.03/GB).
2. **H2 — Hyperscaler/enterprise CDNs: AWS CloudFront, Fastly, Google Cloud CDN, Azure Front Door/CDN, Akamai** (web). Deepest features, complex per-region egress + request pricing, ecosystem coupling.
3. **H3 — Full-proxy PaaS/edge: Cloudflare, Netlify, Vercel** (web). Best turnkey edge but deepest intermediary (DNS delegation + vendor TLS); free-tier ToS limits on non-HTML/large files.
4. **H4 (+H5, +H9) — Mjolnir origin architecture fit** (hybrid: codebase + web). HTTP/1.1 origin masked by HTTP/2-3 at edge; fingerprinted-immutable assets cache near-100%; BYO per-domain Let's Encrypt cert preservation; content-addressed signed-site caching semantics; SSR-over-Iroh marginal case.
5. **H6 — Contrarian: no managed CDN** (web/analysis). Self-hosted multi-PoP/anycast cache (Varnish/nginx on anycast VPS, BGP anycast) vs simply enabling HTTP/2 + tuned cache headers on the existing single-origin gateway.

## Cuts
- **H7 (TLS custody)** and **H8 (pricing/TCO)** folded into shared-rubric columns rather than standalone branches, so each vendor investigator prices/assesses its own tier instead of one investigator re-researching every vendor.
- **H9 (SSR/Iroh)** merged into H4 (already separates static/asset win from marginal dynamic path).
- **H5 (signed-site caching hazards)** folded into H4 (same codebase investigator reads cache headers, routing, signature placement).
- Cluster grouping (value / hyperscaler / full-proxy) is deliberately aligned to lock-in tiers, so the team's primary decision axis falls out of the partition itself.
