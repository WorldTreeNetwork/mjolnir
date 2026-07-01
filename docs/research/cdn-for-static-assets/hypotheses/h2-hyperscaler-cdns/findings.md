Now I'll write the findings document.
The `Write` tool is blocked for this agent type (the harness intercepted it with "Subagents should return findings as text, not write report files"), so I cannot create `/Users/dukejones/work/IdentiKey/mjolnir/docs/research/cdn-for-static-assets/hypotheses/h2-hyperscaler-cdns/findings.md` directly. Returning the full findings as text below for the orchestrator/synthesizer to persist.

---

# Hypothesis: H2 — Hyperscaler/enterprise CDNs buy depth at the cost of complexity and lock-in

## Summary

**Supported, with caveats.** All five hyperscaler CDNs (CloudFront, Fastly, Google Cloud CDN, Azure Front Door, Akamai) can technically front a single custom HTTP/1.1 origin behind a CNAME and terminate modern TLS/HTTP3 at the edge — none requires moving the origin into their cloud. But "deepest features" is uneven: Fastly genuinely buys best-in-class purge speed and real edge compute (Wasm); CloudFront and Azure buy ecosystem integration more than raw CDN capability; Google Cloud CDN buys GCP integration at the cost of mandatory load-balancer scaffolding; Akamai buys enterprise-grade security/scale that is inaccessible and uneconomical at Mjolnir's traffic level. Pricing is real but workable for CloudFront/Front Door/Cloud CDN at 1–5 TB/mo (low hundreds of $/mo); Fastly's public pricing is genuinely opaque above its $50/mo floor; Akamai pricing is contract-only and effectively unavailable below ~$8k/mo. Lock-in is real but **shallow at the DNS/TLS layer** for all five (CNAME + your own cert is generally possible) — the deeper lock-in is in tooling, IAM, and billing-account gravity, strongest for CloudFront (AWS account) and Google Cloud CDN (mandatory Cloud Load Balancing resource), weaker for Fastly and Front Door, and contractual (not technical) for Akamai.

---

## AWS CloudFront

**Features:** ~600+ traditional PoPs plus 1,140+ embedded PoPs inside ISP networks across 300+ cities as of Q1 2026 [1]. HTTP/3 (QUIC) is supported and opt-in per distribution [2]. Gzip and Brotli automatic compression supported for compatible content-types [1]. Edge compute: CloudFront Functions (sub-ms JS for URL rewrites/header manipulation, ~10x cheaper than Lambda@Edge) and Lambda@Edge (full Node.js/Python at regional edge caches) [1]. AWS WAF integrates directly; AWS Shield (DDoS) Standard tier included by default. Signed URLs/signed cookies with trusted signers (time-limited, optional IP restriction) natively supported [9].

**Origin integration:** Custom origins are first-class — "your web application can be hosted on AWS... or on any publicly accessible URL" [3]. CloudFront speaks HTTP/2 or HTTP/3 to viewers while pulling from the origin over HTTP/1.1 or HTTP/2 (origin protocol policy configurable per distribution) — i.e., the gateway's HTTP/1.1-only origin is supported without modification. Regional edge caches act as origin shielding; an explicit Origin Shield feature gives finer control.

**DNS requirement:** CNAME-only. You add an alternate domain name (CNAME) pointing to the CloudFront-assigned hostname (`*.cloudfront.net`); Route53 is **not** required — any DNS provider works [4][5]. The one hard requirement: a custom TLS cert for the alternate domain must be issued/imported into ACM **in us-east-1**, regardless of where the origin lives [4]. ACM's own domain validation needs a DNS record at issuance time — a one-time validation step, not an ongoing delegation requirement.

**TLS / key custody:** Import a third-party cert (e.g., your own Let's Encrypt cert) into ACM in PEM format with full chain, or use ACM's free managed cert (auto-renewed, DNS-validated) [4]. Either way, **AWS holds the private key** for the edge-facing cert (ACM does not allow private key export). The origin can independently run its own LE cert for the CloudFront→origin leg if origin protocol policy is HTTPS-only — Mjolnir's gateway keeps custody of its own origin cert even while ACM/AWS custodies the edge-facing cert. Self-signed certs are explicitly rejected for new CNAME additions [4].

**Pricing model + realistic cost:** Pay-as-you-go NA/EU data transfer out: $0.085/GB for the first 10 TB/mo, dropping at higher tiers [6]. **First 1 TB/mo is free (perpetual free tier, not a 12-month trial), plus first 10M requests/mo free** [6]. HTTPS requests beyond free tier: $0.0100/10,000 [7]. Invalidations: first 1,000 paths/mo free, $0.005/path after — largely moot here since fingerprinted/immutable assets rarely need invalidation [7].
  - *Assumption:* 90% cache hit ratio, traffic mostly NA+EU, ~100 KB average object (→ ~10M req per TB).
  - **~1 TB/mo:** Fully inside the free tier → data transfer $0, requests $0 → **~$0/mo** (best case; this is the perpetual free tier per [6]).
  - **~5 TB/mo:** 4 TB billable @ $0.085/GB = $340; 40M billable requests @ $0.0100/10,000 = $40 → **~$380/mo**.
  - Not included: the origin's own egress to CloudFront on cache misses — CloudFront does not charge AWS-side "data transfer in" from a non-AWS origin, but the origin's own hosting/bandwidth provider will bill that leg under its own bandwidth plan — flagged as an open cost outside CDN billing.
  - A flat-rate plan option also exists (Free/Pro/Business/Premium bundles, e.g. Free = 100 GB + 1M requests/mo, $0/mo) but pay-as-you-go is cheaper at Mjolnir's described traffic [6].

**Lock-in verdict:** DNS/TLS exit cost is low (CNAME-only, BYO or ACM cert, origin untouched). The deeper coupling is **account gravity**: CloudFront is provisioned/billed through an AWS account, ACM certs and CloudFront Functions/Lambda@Edge code are AWS-specific and don't port, and IAM is the de facto access-control plane. Walking away means deleting a distribution and re-pointing DNS — cheap — but any edge logic written in CloudFront Functions/Lambda@Edge must be rewritten for the next vendor.

**Trade-offs:** CloudFront is the closest of the five to "buy depth without buying the full cloud" — single custom origin, CNAME-only DNS, BYO cert, true HTTP/1.1-origin-to-HTTP/3-edge translation, and a perpetual free tier that fully covers the described ~1 TB/mo case. The cost is AWS account/IAM gravity and non-portable edge compute. For a team wary of but not allergic to lock-in, CloudFront is the lowest-friction hyperscaler option of the five.

---

## Fastly

**Features:** ~100+ "Super PoPs" — fewer, much larger PoPs (heavy SSD/RAM) rather than hundreds of small ones [12]. TLS 1.3 with 0-RTT is supported [12]; explicit confirmation of HTTP/3 support was not found in sources gathered (open question, flagged below). Compute (formerly Compute@Edge) runs Rust, JS, or any Wasm-compiled language at the edge with sub-ms cold starts [12]; VCL gives full programmatic control over caching/routing for the classic Delivery product. Fastly Next-Gen WAF applies rule-based + ML detection at every PoP; Edge/Cloud WAF includes always-on DDoS mitigation [12]. **Fastly's Instant Purge propagates globally in ~150ms** — fastest of the five vendors investigated, on par with Cloudflare [10].

**Origin integration:** Custom/non-bucket origins are the default Fastly use case. Shielding is supported — a fixed "shield" PoP sits between edge nodes and your single origin to collapse concurrent requests; Fastly does **not** charge a separate shielding fee, but both edge→shield and shield→origin legs are billed at your contracted per-GB delivery rate (no discount for the internal shield leg) [11].

**DNS requirement:** CNAME-only — point your domain at the Fastly-assigned hostname.

**TLS / key custody:** Two distinct paths: (1) **Self-managed / Custom TLS** — upload your own cert + private key directly via the Fastly control panel or API (256/384-bit ECDSA or 2048-bit RSA keys only) [8]; (2) **Platform TLS** — you still procure your own cert from any CA (e.g., Let's Encrypt) but manage deployment programmatically via Fastly's API; Fastly explicitly does **not** procure certs on your behalf, and you're responsible for renewal [8]. Fastly-managed TLS also exists (Fastly obtains/rotates the cert for you, "5 domains free") but shifts key custody to Fastly. For a team wanting to keep TLS key custody, Fastly's Custom/Platform TLS path is the most accommodating of the five vendors researched (full control, BYO cert, no forced managed-cert path).

**Pricing model + realistic cost:** **This is the weakest-documented pricing of the five.** Fastly's public pricing page does not publish a per-GB table for the core Delivery product — it states a **$50/mo minimum** for the self-serve Usage plan and packaged tiers from $1,500–$6,000/mo [13]. Third-party aggregator estimates (not Fastly's own page, low confidence) put per-GB delivery somewhere in a **$0.08–$0.28/GB** range depending on region/volume, with first 100 GB/mo free [13]. Compute requests: 10M/mo free, then $0.50/1M requests (10M–500M tier) declining at higher volume [13]. Managed Commercial CA cert: $275/domain/yr if you opt for Fastly-managed certs (BYO cert avoids this) [8].
  - *Assumption:* same as CloudFront (90% cache hit, NA/EU, ~100KB objects), and a **$0.10/GB midpoint estimate** since Fastly does not publish an authoritative figure.
  - **~1 TB/mo:** 100 GB free + 900 GB × ~$0.10 = ~$90, but the **$50/mo minimum applies regardless** → **~$90–150/mo** (wide error bars; unverifiable without a sales quote).
  - **~5 TB/mo:** 100 GB free + ~4,900 GB × ~$0.10 (volume discount likely kicking in) → **~$350–500/mo**, again unverified against an actual contract.
  - **Flag: pricing is opaque.** Unlike CloudFront/Front Door/Cloud CDN, Fastly does not publish authoritative per-GB rates for Delivery; real pricing requires a sales conversation once past the free/minimum tier, and the figures above are estimates from secondary sources, not Fastly.com.

**Lock-in verdict:** Lowest DNS/TLS lock-in of the five — CNAME-only, full BYO-cert support with no forced managed-cert path, and VCL (Fastly-specific syntax but well-understood CDN concepts) is not hard to reimplement elsewhere. Compute (Wasm) code is more portable in principle but Fastly's request/response API surface is proprietary, so investment there doesn't transfer directly. No mandatory account-wide resource (no IAM/billing-account gravity comparable to AWS or GCP) — Fastly services are scoped per-customer, not nested inside a larger cloud account.

**Trade-offs:** Fastly genuinely buys the deepest *operational* feature — near-instant (~150ms) purge — relevant if Mjolnir ever needs aggressive invalidation beyond the fingerprinted-asset model. It also has the most accommodating TLS-key-custody story (true BYO cert, no forced hand-over). The cost is pricing opacity: a real $50/mo floor and no public per-GB rate card, so budgeting beyond casual use requires a sales conversation — friction for a self-hosting-minded team that wants to reason about costs without negotiating a contract.

---

## Google Cloud CDN

**Features:** Runs on Google's global edge PoP network (exact 2026 PoP count not found — open question). HTTP/3/QUIC is supported on External HTTP(S) Load Balancing + Cloud CDN [15]. Edge compute is in **Preview** only as of sources gathered: Service Extensions let you run custom code pre-cache in the request path [15] — meaningfully less mature than CloudFront Functions or Fastly Compute. WAF/DDoS via Cloud Armor (Preconfigured rules based on ModSecurity CRS 3.3) is a bolt-on, billed separately [15]. Signed URLs for private content are supported via general GCP load-balancer functionality (not directly verified this pass — flagged).

**Origin integration:** Cloud CDN is **not standalone** — it's a caching layer bolted onto Google Cloud's External HTTPS Load Balancer, which **does** support custom/non-GCP backends (internet network endpoint group), so a single external HTTP/1.1 origin is supported, but only by first standing up a GCP Load Balancer resource [14]. This is the one vendor of the five where the CDN cannot be provisioned independently of a larger compute-networking resource. Cache fill (origin pull) for external origins is billed at "Compute Engine internet egress rates" as a separate line item from cache egress to clients [14].

**DNS requirement:** GCP's External HTTPS LB is normally assigned a **static IP** (A record), not a pure CNAME-to-hostname model. For Google-managed TLS certs, domain ownership is validated via a **CNAME-based DNS authorization** record (e.g., `_acme-challenge.yourdomain` → `*.authorize.certificatemanager.goog`) that must remain in place for cert issuance and renewal [16]. Google Cloud DNS is not mandated — any DNS provider can host this record — but docs warn the CNAME must be the **only** record for that name (some providers' simultaneous TXT+CNAME configs break this) [16].

**TLS / key custody:** Supports Google-managed certs (auto-issued/renewed via the DNS authorization CNAME above) or self-managed certs uploaded via Certificate Manager — BYO cert (including your own LE-issued cert) is supported, keeping key custody with you if desired [16]. The origin's own independent TLS is a separate, origin-side concern not mediated by Cloud CDN.

**Pricing model + realistic cost:** Requires a load balancer forwarding rule: **$0.025/hr for the first 5 rules** (flat) = ~$18.25/mo baseline overhead before any traffic [17]. Cache egress NA/EU: $0.08/GiB for the first 10 TiB/mo, dropping to $0.055/GiB (10–150 TiB) [14]. Cache fill (origin pull) NA/EU: $0.01/GiB [14]. Cache lookup requests: $0.0075/10,000 [14]. Static content served from cache bypasses LB data-processing charges entirely [17].
  - *Assumption:* same as above (90% hit ratio, NA/EU, ~100KB objects).
  - **~1 TB/mo:** egress 1,000 GiB × $0.08 = $80; cache fill ~100 GiB × $0.01 = $1; requests 10M/10,000 × $0.0075 = $7.50; LB $18.25 → **~$107/mo**.
  - **~5 TB/mo:** egress 5,000 GiB × $0.08 = $400; cache fill ~500 GiB × $0.01 = $5; requests 50M/10,000 × $0.0075 = $37.50; LB $18.25 → **~$461/mo**.
  - No free tier was found for Cloud CDN itself (unlike CloudFront's perpetual 1TB free tier) — a meaningful disadvantage at low volume.

**Lock-in verdict:** Moderate-to-high. DNS is CNAME/A-record-only (no delegation required), and TLS key custody can stay with you via self-managed certs. But Cloud CDN cannot exist without a GCP Load Balancer resource, pulling you into the GCP resource model (VPC, backend services, named ports) and billing account even for a "just a CDN in front of one origin" use case — more structural coupling than CloudFront or Fastly, even though the DNS/TLS exit path is just as cheap.

**Trade-offs:** Cloud CDN is workable and reasonably priced for Mjolnir's volumes (~$107–$461/mo), with full BYO-cert support and CNAME-based DNS. Its weaknesses are structural rather than financial: edge compute is still Preview (less mature than CloudFront/Fastly), WAF is a separately-billed bolt-on (Cloud Armor), and — uniquely among the five — you cannot provision the CDN without first standing up a full GCP Load Balancer resource, which is the real "buying into the ecosystem" cost even though DNS/TLS stay portable.

---

## Azure Front Door (Standard/Premium)

**Features:** 192 edge locations across 109 metro cities, plus 4 more in Azure US Government regions [18]. Front Door is mid-transition from Anycast to **unicast** routing for DNS resolution/PoP selection, rolling out March–April 2026 [18] — worth tracking since it changes routing behavior. HTTP/3 support was **not confirmed** in documentation gathered this pass (only HTTP/2 and end-to-end IPv6 were explicitly confirmed) — flagged as an open question, do not assume parity with CloudFront/Fastly/GCP. WAF is available via a separate WAF policy resource with custom + managed rule sets (Premium-only for managed/bot-protection rule sets) [19]. A Rules Engine (match conditions → actions, priority-ordered) provides request/response manipulation roughly analogous to CloudFront Functions, though declarative rather than general-purpose code — less powerful than true edge compute.

**Origin integration:** Explicitly supports non-Azure custom origins ("Custom host" origin type) including on-prem or other-cloud backends [20] — a single HTTP/1.1 custom origin is fully supported. Origin-to-edge protocol is configurable.

**DNS requirement:** CNAME + TXT, not CNAME-only. A DNS **TXT** record is required to validate domain ownership, separate from the **CNAME** that routes traffic [21]. You can add the TXT record first and the CNAME later to avoid downtime during migration [21]. **As of Aug 15, 2025, CNAME-based Domain Control Validation for managed-cert renewal was deprecated** — renewals now require either TXT-record validation or Bring-Your-Own-Certificate, with a stated deadline of **Jan 10, 2026** to reconfigure [21] — given the current date (mid-2026 per system context), any existing Front Door deployment must already have completed this migration; new setups should default to TXT-based validation or BYOC from day one. Azure DNS is not mandated; any DNS provider can host the TXT/CNAME records.

**TLS / key custody:** Two options: Azure-managed cert (auto-rotated, requires the TXT-record validation above to stay current) [21], or **Bring Your Own Certificate (BYOC)**, supported since Sept 2023, validated by matching the cert's CN/SAN to the custom domain [21] — an org can keep custody of its own LE-issued key end-to-end if desired. Managed-cert auto-rotation only works automatically when the CNAME points directly at the Front Door endpoint; otherwise re-validation is needed on each rotation [21].

**Pricing model + realistic cost:** Standard tier base fee: **$35/mo**; Premium: **$330/mo** (Premium adds managed WAF rule sets, bot protection, Private Link — none required by Mjolnir's stated constraints, so Standard is the relevant tier) [22]. Outbound (edge→client) NA/EU: $0.083/GB first 10 TB, dropping to $0.066/GB (10–50 TB) [22]. Edge-to-origin transfer: $0.02/GB [22]. Requests: Standard $0.009/10,000, Premium $0.015/10,000 (first 250M) [22].
  - *Assumption:* same as above.
  - **~1 TB/mo:** base $35 + egress 1,000 GB × $0.083 = $83 + edge-to-origin ~100 GB × $0.02 = $2 + requests 10M/10,000 × $0.009 = $9 → **~$129/mo**.
  - **~5 TB/mo:** base $35 + egress 5,000 GB × $0.083 = $415 + edge-to-origin ~500 GB × $0.02 = $10 + requests 50M/10,000 × $0.009 = $45 → **~$505/mo**.
  - No meaningful free tier beyond the base allocation implied by the flat $35 fee.

**Lock-in verdict:** Moderate. DNS requires a TXT record in addition to the CNAME (more moving parts than pure-CNAME vendors, and the 2025–2026 validation-method deprecation shows Microsoft can force reconfiguration with a hard deadline). BYOC is fully supported, so TLS key custody is not forced into Microsoft's hands. No mandatory Azure compute resource is required the way GCP requires a Load Balancer — Front Door is closer to a standalone product — but the Rules Engine and WAF policies are Azure-specific configuration that doesn't port.

**Trade-offs:** Front Door is mid-pack: reasonable pricing (~$129–$505/mo at Mjolnir's volumes), full custom-origin and BYOC support, but the weakest-confirmed protocol story of the five (no verified HTTP/3) and the most DNS friction (TXT + CNAME, plus a recent forced migration off CNAME-based cert validation with a hard 2026 deadline) — a concrete example of a hyperscaler unilaterally changing a domain-validation mechanism customers depend on. Purge latency has also reportedly degraded to ~20 minutes following a 2025 incident with no committed restoration timeline [10], relevant if Mjolnir's SSR/dynamic paths need fast invalidation (the fingerprinted/immutable asset path is unaffected since those rarely need purging).

---

## Akamai

**Features:** The largest, most mature edge network of the five by reputation (exact current PoP count not verified this pass). Fast Purge is sub-5 seconds for web objects (VOD content purge can extend to 120 minutes) [10]. Cloud Wrapper acts as a configurable shielding layer specifically to reduce origin/cloud-egress costs by maximizing origin offload [23]. Site Shield adds IP-allowlist-based origin protection so the origin only accepts traffic from Akamai's published CIDR ranges [24]. Certificate Provisioning System (CPS) manages cert lifecycle; "Enhanced TLS" is a higher tier with stronger encryption/EV options [24]. Full enterprise WAF/DDoS (Kona Site Defender / App & API Protector) is available but is itself a separately licensed product, not a CDN feature.

**Origin integration:** Standard reverse-proxy CNAME model — create a DNS CNAME pointing your hostname at an Akamai-assigned "edge hostname"; Akamai's edge servers pull from your origin via its own DNS record [25]. A single custom HTTP/1.1 origin is fully supported (this is Akamai's original and primary use case, predating any Akamai-owned storage product).

**DNS requirement:** CNAME-only for routing (no delegation required) [25]. TLS requires certs installed at **both** the edge layer (via CPS) and validated against the origin if using the "custom origin, publicly trusted certificate" mode [24] — both legs need valid certs, similar in spirit to CloudFront's origin-protocol-policy=HTTPS option.

**TLS / key custody:** CPS can manage full lifecycle of edge-facing certs; whether Akamai supports a pure self-managed/BYO-key workflow comparable to Fastly's Custom TLS was **not conclusively confirmed** in sources gathered — flagged as an open question requiring direct Akamai documentation or a sales conversation, since Akamai's enterprise contract model often bundles cert management into property configuration rather than exposing a simple self-serve upload API like Fastly/GCP/CloudFront.

**Pricing model + realistic cost:** **Entirely contract-based — no public rate card.** Reported real-world figures (third-party aggregation, not Akamai's own pricing page — treat as indicative only): overall accounts range **$5,000–$150,000+/mo** depending on volume/product mix; small-to-mid accounts at 5–20 TB/mo commonly land at **$8,000–$25,000/mo** [26]. Per-GB contract rates reportedly range $0.012/GB at petabyte scale up to $0.035–$0.060/GB for low-volume accounts, with APAC/LATAM 2–3x NA/EU [26]. A 3% pass-through surcharge took effect April 1, 2026, plus up to 10% contract-renewal price adjustments [26]. Large customers reportedly negotiate 30–50% off list; small/mid accounts get materially worse rates [26].
  - **At Mjolnir's stated ~1–5 TB/mo:** Akamai is almost certainly **below the threshold where direct enterprise contracts are economical or even accessible** — the cited "small/mid" tier already starts at 5 TB/mo and $8k/mo, i.e., likely 20–100x more expensive than CloudFront/Front Door/Cloud CDN at the same volume. **Cost at 1–5 TB/mo is effectively unverifiable without a sales quote**, flagged as the weakest fit of the five vendors on pure economics.

**Lock-in verdict:** Low *technical* lock-in (CNAME-only DNS, standard reverse-proxy model, no mandatory account-wide cloud resource), but high *commercial* lock-in: contract-only pricing with multi-year terms is standard in the enterprise CDN market, renewal-time price increases (the 2026 10% adjustment is a live example), and the absence of a self-serve path makes "just trying it" or walking away mid-contract materially harder than any of the other four vendors.

**Trade-offs:** Akamai likely buys the deepest security/scale features of the five (Kona/App & API Protector, Site Shield, Cloud Wrapper, sub-5s Fast Purge) but is priced and packaged for enterprises running tens of TB/mo or more, with mandatory sales engagement and contract terms. At Mjolnir's described 1–5 TB/mo, Akamai is the clearest case in this rubric of "deepest features, least accessible economics" — almost certainly the wrong fit on cost alone, independent of the technical lock-in question.

---

## Confidence

**Level**: medium

Core mechanics (CNAME-only vs CNAME+TXT DNS, BYO-cert vs managed-cert support, custom-origin support) are corroborated by each vendor's own official documentation and are high-confidence. Pricing arithmetic is internally consistent but rests on (a) official current pricing pages for CloudFront/Cloud CDN/Front Door, and (b) explicitly-flagged secondary/estimated figures for Fastly (no public per-GB rate) and Akamai (no public rate card at all) — those two vendors' cost estimates should be treated as directional, not quotable. PoP counts, HTTP/3 confirmation for Fastly/Front Door, and Akamai's BYO-TLS-key option were not independently cross-verified across multiple sources and are individually flagged as open questions below.

## Sources

- [1] **url**: https://www.signisys.com/blog/amazon-cloudfront/ — "AWS CloudFront expanded past 600 PoPs in Q1 2026, plus 1,140+ embedded PoPs in ISP networks; Brotli/gzip auto-compression; CloudFront Functions vs Lambda@Edge"
- [2] **url**: https://aws.amazon.com/blogs/aws/new-http-3-support-for-amazon-cloudfront/ — "HTTP/3 support for Amazon CloudFront, opt-in via distribution settings"
- [3] **url**: https://aws.amazon.com/cloudfront/pricing/ — "Your web application can be hosted on AWS... or on any publicly accessible URL"; flat-rate plan tiers
- [4] **url**: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cnames-and-https-requirements.html — "Certificate must be requested/imported in us-east-1; X.509 PEM format with full intermediate chain; self-signed certs rejected for new CNAMEs"
- [5] **url**: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/CNAMEs.html — "Use custom URLs by adding alternate domain names (CNAMEs)"
- [6] **url**: https://aws.amazon.com/cloudfront/pricing/ — "First 1TB/month free across all regions; first 10M requests/month free; NA/EU data transfer $0.085/GB first 10TB tier"
- [7] **url**: https://perfsys.com/blog/cloudfront-pricing-guide/ ; https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/PayingForInvalidation.html — "HTTPS requests $0.0100/10,000; first 1,000 invalidation paths/month free, $0.005/path after"
- [8] **url**: https://www.fastly.com/documentation/guides/getting-started/domains/securing-domains/setting-up-tls-with-your-own-certificates/ ; https://docs.fastly.com/products/platform-tls — "Self-managed TLS: upload cert+key; Platform TLS: BYO cert from any CA incl. Let's Encrypt"
- [9] **url**: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-signed-urls.html — "CloudFront signed URLs: signature, expiration, optional IP restriction"
- [10] **url**: aggregated WebSearch results citing fastly.com, blog.cloudflare.com benchmarking post, Microsoft Q&A thread — "Fastly ~150ms global purge; Akamai Fast Purge sub-5s web objects (120min VOD); CloudFront 10-15min; Azure Front Door ~20min, no committed restoration timeline" — purge-speed figures are third-party aggregated, treat CloudFront/Azure figures as indicative
- [11] **url**: https://blog.blazingcdn.com/en-us/understanding-fastlys-origin-shield-and-its-cost-implications — "Fastly does not charge separately for origin shield; both legs billed at contracted per-GB rate"
- [12] **url**: aggregated WebSearch results (fastly.com/resources, docs.fastly.com/products) — "~100+ Super PoPs; TLS 1.3 0-RTT; Compute Wasm sub-ms cold start; Next-Gen WAF" — HTTP/3 for Fastly not explicitly confirmed, flagged open
- [13] **url**: https://www.fastly.com/pricing — "Self-serve Usage plan $50/mo; packaged tiers $1,500-$6,000/mo; Compute 10M req/mo free then $0.50/1M" — per-GB range from third-party blog, explicitly unverified
- [14] **url**: https://cloud.google.com/cdn/pricing — "Cache egress NA/EU $0.08/GiB first 10TiB; cache fill $0.01/GiB; cache lookup requests $0.0075/10,000"
- [15] **url**: aggregated WebSearch (docs.cloud.google.com/architecture, docs.cloud.google.com/armor) — "HTTP/3 on External HTTP(S) LB + Cloud CDN; Service Extensions in Preview; Cloud Armor WAF billed separately"
- [16] **url**: https://docs.cloud.google.com/certificate-manager/docs/dns-authorizations ; https://docs.cloud.google.com/certificate-manager/docs/domain-authorization — "DNS authorization via CNAME; must be only record for that name; self-managed cert upload also supported"
- [17] **url**: https://cloud.google.com/load-balancing/pricing — "Up to 5 forwarding rules for $0.025/hr flat; cached content bypasses LB data-processing charges"
- [18] **url**: https://learn.microsoft.com/en-us/azure/frontdoor/edge-locations-by-region ; https://techcommunity.microsoft.com/blog/azurenetworkingblog/azure-front-door-implementing-lessons-learned-following-october-outages/4479416 — "192 edge locations / 109 metro cities; Anycast→unicast migration March-April 2026"
- [19] **url**: https://learn.microsoft.com/en-us/azure/web-application-firewall/afds/afds-overview ; https://learn.microsoft.com/en-us/azure/frontdoor/front-door-rules-engine — "WAF policy with custom + managed rules; Rules Engine"
- [20] **url**: https://learn.microsoft.com/en-us/azure/frontdoor/origin — "Custom host origin type supports non-Azure backends"
- [21] **url**: https://learn.microsoft.com/en-us/azure/frontdoor/standard-premium/how-to-add-custom-domain ; https://learn.microsoft.com/en-us/azure/frontdoor/standard-premium/how-to-configure-https-custom-domain — "TXT record for domain validation, separate CNAME for routing; BYOC since Sept 2023; CNAME-based DCV deprecated Aug 15 2025, migrate by Jan 10 2026"
- [22] **url**: https://azure.microsoft.com/en-us/pricing/details/frontdoor/ ; https://learn.microsoft.com/en-us/azure/frontdoor/understanding-pricing — "Standard base $35/mo, Premium $330/mo; NA/EU outbound $0.083/GB first 10TB; edge-to-origin $0.02/GB; requests $0.009/10k Standard"
- [23] **url**: https://www.akamai.com/products/cloud-wrapper — "Cloud Wrapper: custom caching layer to maximize origin offload and reduce cloud egress costs"
- [24] **url**: https://techdocs.akamai.com/property-mgr/docs/the-custom-origin-public ; https://techdocs.akamai.com/site-shield/docs/welcome-site-shield ; https://learn.akamai.com/en-us/products/core_features/certificate_provisioning_system.html — "Certs required at both edge and origin; Site Shield IP-CIDR allowlisting; CPS cert lifecycle management"
- [25] **url**: https://techdocs.akamai.com/property-mgr/docs/redirect-users-edge-servers ; https://techdocs.akamai.com/property-mgr/docs/custom-origin-prerequisites — "CNAME to Akamai-assigned edge hostname; origin DNS record configured separately"
- [26] **url**: https://costbench.com/software/cdn-edge/akamai/hidden-costs/ ; https://www.streamingmediablog.com/2026/03/akamai-price-adjustments.html — "Contract-only pricing; reported range $5,000-$150,000+/mo; small/mid 5-20TB/mo $8,000-$25,000/mo; 3% surcharge effective April 1 2026; up to 10% renewal adjustments" — third-party aggregated, no public rate card exists

## Open Questions

- **Fastly HTTP/3 support**: not explicitly confirmed via official Fastly documentation (only TLS 1.3 0-RTT confirmed) — needs direct check before treating as parity with CloudFront/GCP.
- **Azure Front Door HTTP/3 support**: not confirmed at all in sources gathered (only HTTP/2 + IPv6 confirmed) — material gap if HTTP/3 is a hard requirement.
- **Akamai BYO-TLS-key support**: unclear whether Akamai's CPS supports true self-managed/upload-your-own-key workflow vs. key custody effectively defaulting to Akamai in standard enterprise contracts — needs direct TechDocs check or sales conversation.
- **Akamai realistic cost at 1-5 TB/mo**: cited figures all describe 5TB/mo+ accounts at $8k-25k/mo; whether Akamai is reachable at all below that volume (e.g. via reseller/marketplace listing with lower floor) is unverified — the single biggest pricing gap in this research.
- **Whether CloudFront's "data transfer from non-AWS origins billed at standard internet transfer rates" is an AWS-billed charge or simply describes the origin's own bandwidth provider billing it** — ambiguous phrasing in source [6]'s summary; matters for whether there's a hidden AWS-side fee for pulling from Mjolnir's custom origin beyond documented client-egress pricing.
- **Exact current Google Cloud CDN and Akamai PoP counts** — not found in sources gathered; would complete the "anycast PoP count/coverage" rubric line for those two vendors.
- **Whether Fastly's quoted $0.08-$0.28/GB range (and this report's $0.10/GB midpoint estimate) resembles a real negotiated rate at Mjolnir's volume** — entire Fastly pricing section rests on secondary sources; a real sales quote would materially change the H2 cost comparison against CloudFront/Front Door/Cloud CDN.
Investigation complete. Summary for the orchestrator: H2 is **supported with caveats** — all five hyperscaler CDNs can front Mjolnir's single HTTP/1.1 custom origin via CNAME without forced cloud migration, but they diverge sharply on accessibility:

- **CloudFront**: lowest friction, CNAME-only DNS, BYO/ACM cert, perpetual 1TB free tier covers the ~1TB/mo case (~$0/mo), ~$380/mo at 5TB/mo. Lock-in is AWS account/IAM gravity, not DNS/TLS.
- **Fastly**: best technical depth (150ms purge, true BYO-cert/Wasm compute, no forced cloud-account coupling) but **pricing is genuinely opaque** — no public per-GB rate card, $50/mo floor, estimates only (~$90-500/mo, low confidence).
- **Google Cloud CDN**: reasonably priced (~$107-461/mo) but uniquely requires standing up a full GCP Load Balancer resource just to get a CDN — the deepest structural lock-in of the five even though DNS/TLS stay portable.
- **Azure Front Door**: mid-pack pricing (~$129-505/mo), full BYOC support, but weakest-confirmed HTTP/3 story and most DNS friction (CNAME+TXT, plus a 2025-2026 forced cert-validation migration).
- **Akamai**: deepest enterprise features but contract-only pricing with no public rate card; cited "small/mid" tier already starts at 5TB/mo and $8k-25k/mo — almost certainly inaccessible/uneconomical at Mjolnir's 1-5TB/mo scale.

The findings document (full per-vendor rubric, arithmetic, 26 sources, open questions) is included verbatim in my prior message since the `Write` tool was blocked for this agent role with the message "Subagents should return findings as text, not write report files." The orchestrator/synthesizer should persist that content to `/Users/dukejones/work/IdentiKey/mjolnir/docs/research/cdn-for-static-assets/hypotheses/h2-hyperscaler-cdns/findings.md` itself.
Investigation already complete — findings were delivered in full in my previous message (per-vendor rubric for CloudFront, Fastly, Google Cloud CDN, Azure Front Door, and Akamai, with arithmetic for 1TB/mo and 5TB/mo scenarios, 26 cited sources, and an open-questions list).

Nothing further to do on my end: the `Write` tool is blocked for this agent role, so the target file `/Users/dukejones/work/IdentiKey/mjolnir/docs/research/cdn-for-static-assets/hypotheses/h2-hyperscaler-cdns/findings.md` was never created — the orchestrator/synthesizer needs to persist the text I returned into that path.

Quick recap of the verdict for hand-off: H2 is supported with caveats — CloudFront is the lowest-friction hyperscaler option (CNAME-only, BYO cert, free at ~1TB/mo); Fastly has the deepest operational features but opaque pricing; Google Cloud CDN is reasonably priced but uniquely requires a GCP Load Balancer resource; Azure Front Door is mid-pack with the most DNS friction; Akamai's enterprise depth is real but inaccessible/uneconomical at Mjolnir's 1-5TB/mo scale.
Confirming: this investigation is finished and no further action is pending on my end. The complete H2 findings (per-vendor rubric for AWS CloudFront, Fastly, Google Cloud CDN, Azure Front Door, and Akamai — features, origin integration, DNS requirements, TLS/key custody, pricing arithmetic at 1TB/mo and 5TB/mo, lock-in verdict, trade-offs, 26 sources, and open questions) were already delivered in full as text in my second message of this conversation, since the `Write` tool is blocked for this agent role.

That content still needs to be persisted by the orchestrator/synthesizer to:
`/Users/dukejones/work/IdentiKey/mjolnir/docs/research/cdn-for-static-assets/hypotheses/h2-hyperscaler-cdns/findings.md`

I have no further tool calls to make — awaiting next instruction or hand-off.
No further action needed from me — this task is complete and I'm idle, awaiting the next instruction from the orchestrator. The H2 findings were fully delivered as text two messages ago (and reiterated since), and the file-write responsibility was already handed off since `Write` is blocked for this agent role.
Acknowledged — idle, no pending work. The H2 hyperscaler-CDN investigation is complete and findings were already returned in full as text earlier in this conversation. I'll wait for the next prompt rather than repeat the summary again.
Idle.
Idle.
Idle.
