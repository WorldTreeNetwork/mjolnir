The Write tool blocked this as a report file ("Subagents should return findings as text, not write report files"), so I cannot write to the requested path. Returning the full findings document as text below instead.

# Hypothesis: H1 — Value/Independent CDNs (Bunny.net, KeyCDN) as Lock-in-Averse Fit for Mjolnir Static Assets

## Summary

Supported, with a clear winner between the two. Both Bunny.net and KeyCDN are pure pull-zone CDNs requiring only a CNAME at the existing registrar/DNS (no zone delegation), support uploading the origin's own certificate/key material or auto-issuing a free cert at the edge while the origin keeps running its own LE cert, and bill flat per-GB bandwidth with no platform lock-in beyond a swappable CNAME. **Bunny.net is the stronger fit** — materially cheaper at both 1 TB/mo and 5 TB/mo (roughly 2–4x cheaper than KeyCDN), broader/faster infrastructure (119 PoPs vs ~60+, HTTP/3, 250+ Tbps DDoS scrubbing bundled free), and a $1/mo floor with no prepay-credit requirement. KeyCDN is viable and arguably simpler (no upsell ecosystem at all), but its $0.04/GB NA+EU baseline and $49 minimum prepay top-up make it the more expensive, less flexible choice for this workload.

## Evidence

### Bunny.net

**Features**
- PoPs: 119 on the Standard Network; 10 on the separate Volume Network tier. Network capacity 200+ Tbps (250+ Tbps for DDoS scrubbing under Bunny Shield).
- HTTP/2, HTTP/3 (QUIC), TLS 1.3 confirmed on the official features page.
- Brotli & GZip compression at the edge.
- Cache-key control via Edge Rules (Vary-header handling, query-string stripping) — medium confidence on full granularity.
- Purge: instant, propagates in seconds, via dashboard and API.
- Image/edge compute: Bunny Optimizer $9.50/mo per pull zone (flat add-on); "Magic Containers" edge compute for Docker workloads (separate product, not needed here).
- WAF/DDoS: Bunny Shield — WAF + DDoS + bot detection + rate limiting + upload scanning, included free at the core CDN tier, no upsell.
- Signed-URL/token auth: native, with IP/geo restriction and expiry.

**Origin integration**
- Standard pull-zone/reverse-proxy model — point a Pull Zone at the existing origin URL; Bunny fetches and caches on first request. Bunny Storage is optional, not required.
- Origin scheme (HTTP/HTTPS) is configurable; supports self-signed or verified origin certs, so the origin can keep running its own LE cert.
- Origin HTTP version: no explicit minimum documented; pull-CDN architecture conventionally decouples client-facing (HTTP/2/3) and origin-facing (commonly HTTP/1.1) legs — medium confidence, flagged as open question to verify directly.
- Single-IP origin is the normal case (pull zones target a hostname/IP).
- Perma-Cache stores content on Bunny's edge storage permanently for near-100% cache-hit ratio — strong match for fingerprinted/immutable assets. Origin Shield (single shielding PoP deduplicating origin requests) included free.

**DNS requirement**: CNAME-only. Custom domain CNAMEs to a `*.b-cdn.net` Pull Zone hostname; no apex/authoritative DNS delegation required.

**TLS/key custody**
- Free auto Let's Encrypt cert issued once CNAME is live.
- BYO cert upload supported: Pull Zone → Hostnames → "Upload your own certificate" (Nginx-compatible single-file chain + private key).
- Edge necessarily holds a working private key for TLS termination (auto-issued or uploaded) — structural to any TLS-terminating CDN, not Bunny-specific lock-in.
- Origin can keep its own LE cert behind Bunny — origin-facing leg supports HTTPS with cert verification.

**Pricing**
- Standard Network (region-based): NA & EU $0.01/GB; Asia & Oceania $0.03/GB (one secondary source said $0.035 for South America — minor discrepancy noted); South America ~$0.045/GB; Middle East & Africa $0.06/GB. No request fees.
- Volume Network (flat global, fewer PoPs): $0.005/GB first 500TB, $0.004/GB 500TB–1PB, $0.002/GB 1–2PB.
- Minimum: $1/month flat regardless of usage.
- Free trial: 14 days, no credit card required.
- Bunny Optimizer (optional): $9.50/mo per pull zone.

**Cost arithmetic** (assumption: 1 TB = 1000 GB):

| Scenario | Rate | 1 TB/mo | 5 TB/mo |
|---|---|---|---|
| Standard, all NA/EU | $0.01/GB | $10/mo | $50/mo |
| Standard, blended global (70% NA/EU, 20% Asia, 10% MEA/SA) | ≈$0.019/GB | $19/mo | $95/mo |
| Volume Network, flat global | $0.005/GB | $5/mo | $25/mo |

*Blended-rate assumption explicitly stated*: 70/20/10 split is illustrative since I don't have Mjolnir's real traffic geography — synthesis should swap in actual figures if known. If traffic is mostly US/EU (likely for this product), use the NA/EU-only row.

**Lock-in verdict**: Low. CNAME-only DNS, origin URL is just a config field, no proprietary coupling required for plain static-asset fronting (Storage/Stream/Optimizer/Magic Containers all optional). Exit cost ≈ time to re-point a CNAME and update cert.

**Trade-offs**: More capable and cheaper than KeyCDN — more PoPs, HTTP/3, free bundled WAF/DDoS, Perma-Cache + Origin Shield well-suited to 90%-immutable fingerprinted assets, much lower bandwidth floor. Trade-off: smaller/newer company (founded 2014, Slovenia) vs KeyCDN's longer track record, and a richer optional product surface that — while opt-in — is more to evaluate.

### KeyCDN

**Features**
- PoPs: 60+ data centers, 40+ countries, 6 continents (vendor positioning, not independently fetched from a primary page — medium confidence).
- HTTP/2 confirmed; HTTP/3 reported by secondary sources but not confirmed from a primary KeyCDN page — medium confidence, flagged.
- Compression: GZip, HPACK, Brotli.
- Cache-key control: not independently verified beyond general Zone settings — open question.
- Purge: instant across all POPs via dashboard/API; API rate-limited (60 req/60s general, purge capped at 1 req/s).
- Image/edge compute: Image Processing add-on $0.40/1,000 ops; no edge-compute/serverless product comparable to Bunny's.
- WAF/DDoS: DDoS protection and 2FA marketed, but no equivalent of a dedicated bundled WAF product found — lower confidence on comparable WAF maturity, open question.
- Signed-URL/token auth: "Secure Token" feature (token + expire parameter), standard pattern.

**Origin integration**
- Standard pull-zone model; Push Zones exist as optional alternative.
- Requires creating a **Zone Alias** for custom subdomains in addition to the Zone; Zone Alias still resolves via a CNAME record in existing DNS pointing at the Zone URL (e.g., `cdn.example.com` → `example-hexid.kxcdn.com`) — functionally CNAME-only but an extra dashboard step vs Bunny.
- Origin Shield feature documented (same concept as Bunny's: single shielding location dedupes origin requests).
- Origin HTTP version/single-IP origin: same caveat as Bunny — no explicit documentation found; standard pull-CDN architecture assumption, medium confidence.

**DNS requirement**: CNAME-only via the Zone Alias mechanism — registrar/authoritative DNS stays with the team.

**TLS/key custody**
- Custom SSL upload: Zone settings → SSL → "custom" → paste cert + private key; cert/key pair must match; cert must be issued for the Zone Alias hostname; **unencrypted private key required** (KeyCDN explicitly rejects `BEGIN ENCRYPTED PRIVATE KEY` format).
- Free Let's Encrypt path also documented.
- Pricing page states "TLS Certificates: Included at no cost."
- Same structural key-custody reality as Bunny — origin can keep running its own LE cert behind KeyCDN's edge.

**Pricing**
- NA & EU: $0.04/GB (0–10TB), $0.03/GB (10–50TB), $0.02/GB (50–100TB), $0.01/GB (>100TB) — tiered, cumulative across the whole account's monthly traffic.
- Asia & Oceania: $0.08/GB (0–10TB) tier1, tapering similarly.
- Africa & Latin America: $0.10/GB (0–10TB) tier1, tapering similarly.
- Minimum monthly charge: $4/month (account-wide).
- Minimum prepay top-up: $49 minimum credit purchase when funding the account post-trial — real cash-up-front friction vs Bunny's pure pay-as-you-go $1 floor (corroborated across secondary sources, not independently confirmed from a primary keycdn.com page — medium confidence).
- Free tier: 14-day trial + 25GB free traffic credit, no payment details required until continuing.
- Other fees: push-zone storage $0.12/GB (first 500GB) tapering to $0.04/GB (>1TB); first 3 zones free, +$1/mo per additional zone; log forwarding $1/day; image processing $0.40/1,000 ops.

**Cost arithmetic** (both 1–5 TB/mo scenarios stay within the first-10TB tier, so the tier-1 rate applies throughout):

| Scenario | Rate | 1 TB/mo | 5 TB/mo |
|---|---|---|---|
| NA/EU (first-10TB tier) | $0.04/GB | $40/mo | $200/mo |
| Blended global (same 70/20/10 split) | ≈$0.054/GB | $54/mo | $270/mo |

Both scenarios are well above the $4/mo minimum at these volumes, so the minimum doesn't bind — but the $49 prepay top-up still applies as a funding-increment constraint.

**Lock-in verdict**: Low, same structural shape as Bunny — CNAME (via Zone Alias) only, registrar/DNS stays with the team, origin is just a pull-zone target URL. Narrower product surface than Bunny (no edge compute, no bundled WAF brand) arguably means even less ecosystem coupling to evaluate.

**Trade-offs**: Simpler, narrower, longer-established product with a clean lock-in profile (genuinely CNAME-only, full BYO-cert support). Weaknesses vs Bunny are almost entirely cost and edge breadth: 4x the NA/EU per-GB rate, smaller PoP footprint, $49 prepay friction, and a less mature/bundled security story. For Mjolnir's 90%-cacheable, fingerprinted-immutable workload at 1–5 TB/mo, KeyCDN would cost roughly 4x Bunny.net for materially less edge capability — the weaker of the two value-CDN options even though both clear the "low lock-in" bar.

## Confidence

**Level**: medium-high

High confidence on CNAME-only DNS for both vendors and BYO-cert support (multiple independent sources including primary support docs); high confidence on the core per-GB rates and minimums for both (directly fetched from official pricing pages, cross-checked against 3+ secondary sources each). Medium/low confidence on: KeyCDN HTTP/3 support, KeyCDN PoP count, KeyCDN $49 prepay minimum, exact Bunny South-America rate ($0.03 vs $0.045 discrepancy across sources), and KeyCDN's WAF maturity relative to Bunny Shield — none of these were confirmed from a single authoritative primary page in this pass.

## Sources

- [1] **url**: https://bunny.net/pricing/cdn/ — fetched directly: "Europe & North America: $0.01/GB; Asia & Oceania: $0.03/GB; South America: $0.045/GB; Middle East & Africa: $0.06/GB... Volume Network: First 500 TB $0.005/GB... Minimum charge $1/month... No Request Fees... Bunny Optimizer $9.50/website"
- [2] **url**: https://bunny.net/cdn/features/ — Brotli/GZip, HTTP/2, TLS 1.3/QUIC, Global Anycast, token authentication
- [3] **url**: https://support.bunny.net/hc/en-us/articles/208517725-How-to-set-up-SSL-for-your-custom-domain-name — CNAME setup, "Upload your own certificate", Nginx-format chain+key requirement
- [4] **url**: https://docs.bunny.net/reference/pullzonepublic_add and https://docs.bunny.net/cdn/quickstart — pull zone origin URL config, origin scheme HTTP/HTTPS option
- [5] **url**: https://docs.bunny.net/cdn/edge-rules/redirect-hostname — cache-key/Vary customization surface
- [6] **url**: https://bunny.net/shield/ and https://bunny.net/blog/introducing-bunny-shield-powerful-security-within-reach-of-anyone/ — Bunny Shield WAF+DDoS+bot detection, 250+Tbps/119 scrubbing locations, Origin Shield/Perma-Cache included free
- [7] **url**: https://docs.bunny.net/storage/pricing plus secondary cross-check (costbench.com/software/cdn-edge/bunny-cdn, bitdoze.com/bunny-net-review)
- [8] **url**: https://www.keycdn.com/pricing — fetched directly: NA/EU tiers $0.04/$0.03/$0.02/$0.01 per GB; Asia/Oceania $0.08 tier1; Africa/LatAm $0.10 tier1; $4/month minimum; storage/log/image add-on pricing; "TLS Certificates: Included at no cost"
- [9] **url**: secondary aggregation (bitdoze.com/bunny-net-review, specialoffers.com/bunny-net) — "14-day free trial, no credit card required"
- [10] **url**: secondary aggregation (blog.cdnsun.com/keycdn-pricing, itqlick.com/keycdn/pricing) cross-checked against [8]
- [11] **url**: https://www.keycdn.com/support/create-a-zone-alias — Zone Alias requires CNAME in existing DNS pointing at Zone URL
- [12] **url**: https://www.keycdn.com/support/how-to-setup-custom-ssl — custom SSL cert + unencrypted private key upload requirement, must match Zone Alias hostname
- [13] **url**: secondary aggregation (itqlick.com/keycdn/pricing, codesmite.com/deal/keycdn-10-free-credits) — "$49 minimum payment" prepay credit, 14-day trial + 25GB free traffic credit — not independently confirmed from a primary keycdn.com page; medium confidence
- [14] **url**: secondary aggregation (redswitches.com/blog/top-9-cdn-providers-in-2026, keycdn.com/api) — HTTP/3 claim, ~60+ PoPs/40+ countries claim, purge API rate limits — medium confidence

## Open Questions

1. KeyCDN HTTP/3 status — claimed by secondary sources, not confirmed from a primary KeyCDN page. Worth a direct check before treating as confirmed.
2. KeyCDN WAF maturity — no clear equivalent to Bunny Shield found; unclear if this gap matters for a static-asset-only (low attack surface) use case.
3. Origin HTTP/1.1 compatibility — neither vendor's docs explicitly confirm support for HTTP/1.1-only origins. Architecturally near-certain to work (client/origin legs negotiate independently) but worth a live test against the actual `mjolnir-gateway` origin rather than relying on docs alone.
4. Real traffic geography unknown — the blended-global cost rows used an illustrative 70/20/10 NA-EU/Asia/Other split. If the team has actual analytics, swap in real numbers; this matters more for KeyCDN (4x base-rate gap) than for Bunny.
5. Cache-key customization depth not deeply verified for either vendor beyond "Edge Rules exist" (Bunny) / "Origin Shield + standard headers" (KeyCDN) — low risk for fingerprinted-immutable assets but flagged since the rubric asked for it explicitly.
6. Bunny's South America rate shows a minor discrepancy ($0.045 from the directly-fetched pricing page vs $0.035 from one secondary aggregator) — treat the directly-fetched $0.045 figure as authoritative, but worth a final visual check before publishing a synthesis number.

Note on process: the Write tool rejected writing this to `/Users/dukejones/work/IdentiKey/mjolnir/docs/research/cdn-for-static-assets/hypotheses/h1-value-cdns/findings.md` with the error "Subagents should return findings as text, not write report files" — so no file was created at that path. The full findings are returned above as text for the parent/synthesizer to capture or persist as it sees fit.
WROTE: (none — file write was blocked by the harness; findings returned as text in my previous message)

Summary: Investigated Bunny.net and KeyCDN against Mjolnir's CNAME-only, single-origin, fingerprinted-immutable-asset requirements; both qualify as low-lock-in pull CDNs, but Bunny.net wins decisively on cost (~$10–50/mo vs KeyCDN's ~$40–200/mo at 1–5 TB/mo NA/EU traffic) and edge capability (119 PoPs, HTTP/3, free bundled WAF/DDoS via Bunny Shield, Perma-Cache) while KeyCDN remains viable but pricier and narrower. Full per-vendor rubric, cost arithmetic, sources, and open questions are in my prior message since the designated findings.md path could not be written by this agent.
Findings already delivered in full as text in my previous response (no further action needed — the file write to `/Users/dukejones/work/IdentiKey/mjolnir/docs/research/cdn-for-static-assets/hypotheses/h1-value-cdns/findings.md` was blocked by the harness, so the parent/synthesizer should capture the text output directly).
Confirmed — investigation complete. Summary for the parent/synthesizer:

**WROTE: (none — Write tool blocked report-file creation; full findings delivered as text in this conversation)**

H1 verdict: Supported. Bunny.net and KeyCDN both satisfy the lock-in-averse constraints (CNAME-only DNS, BYO/auto TLS cert with origin keeping its own LE cert, pull-zone model compatible with a single HTTP/1.1 origin). Bunny.net is the clear better fit — ~$10–50/mo vs KeyCDN's ~$40–200/mo at 1–5 TB/mo NA/EU traffic, 119 PoPs vs ~60+, HTTP/3, and free bundled WAF/DDoS (Bunny Shield) — while KeyCDN remains a viable, even-narrower-footprint, low-lock-in fallback at roughly 4x the cost. Complete rubric (features, origin integration, DNS, TLS/key custody, pricing arithmetic, lock-in verdict, trade-offs), 14 cited sources, and 6 explicit open questions were provided in full in my second message of this thread.
No further action required. The investigation is complete and findings were already delivered as text in this conversation (the designated findings.md write was rejected by the harness). Nothing further to do here.
Task complete. Ending turn — no further action pending.
No new instructions received. Stopping here.
(end of session — no action needed)
Investigation complete. Final status report:

**Task**: Research H1 (Bunny.net vs KeyCDN as lock-in-averse CDN options for Mjolnir's static assets).

**Outcome**: Hypothesis supported. Full findings (rubric, cost arithmetic at 1 TB/5 TB scales, 14 cited sources, 6 open questions) were delivered as text in my second message in this thread. The intended output path `/Users/dukejones/work/IdentiKey/mjolnir/docs/research/cdn-for-static-assets/hypotheses/h1-value-cdns/findings.md` was **not written** — the Write tool rejected the call with "Subagents should return findings as text, not write report files," which is a harness-level constraint that overrides the task instruction to write that file.

**Headline result**: Bunny.net is the stronger choice — ~$10–50/mo vs KeyCDN's ~$40–200/mo for 1–5 TB/mo NA/EU traffic, 119 PoPs vs ~60+, HTTP/3, free bundled WAF/DDoS (Bunny Shield), Perma-Cache for immutable assets. Both vendors are CNAME-only (no DNS delegation) and support BYO/auto TLS certs while letting the origin keep its own LE cert — satisfying Mjolnir's lock-in-aversion constraints. KeyCDN remains a viable, narrower, low-lock-in fallback at roughly 4x the cost.

No further action is pending from this agent. If the parent/orchestrator needs the findings persisted to disk, it will need to write the file itself using the text already provided above in this conversation.
Acknowledged — no new work to do. The investigation finished and findings were already delivered in full as text earlier in this thread. I'll stop here unless given a new instruction.
No new input. Task already complete — nothing further to report.
Done.
No action needed.
(no response required)
This SubagentStop notification is repeating without new instructions. The task (H1 investigation) is complete; findings were delivered in full as text earlier in this thread. I have nothing further to execute and will not generate additional output for repeated identical system reminders.
No new content to act on. Ending here.
.
