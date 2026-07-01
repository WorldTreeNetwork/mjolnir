# ADR 0001 — Edge strategy: CDN vs Sites-offload vs self-hosted caching proxy

**Status:** Proposed
**Date:** 2026-07-01
**Context epic:** gateway local-routing (`mjolnir-l79`)
**Builds on:** [`../research/cdn-for-static-assets/`](../research/cdn-for-static-assets/synthesis.md)

## Context

The ~7s cold-start on `zine.identikey.io` was Iroh overlay connection setup to a
co-located VM. It is **fixed** — the gateway now serves co-located VMs over direct local
TCP (154ms warm, live). So HTTP/2 and asset caching are no longer *fixes*; they are
*optimizations* (client-side multiplexing, offloading static bytes from the VM,
geographic latency).

Two facts shape the decision:

1. **The gateway is a transparent HTTP/1.1 byte-pipe** (`read_until_headers` → splice),
   using **DNS-01** ACME. This is a feature: ~7 MB RAM, trivially reliable, deployed
   cleanly serving all prod traffic. It is *not* an HTTP server — it cannot cache or
   speak h2 without becoming one.
2. **There are two distinct origin surfaces:** (a) content-addressed **static** sites
   served from host disk by `Sites.Server`/Bandit (no VM), and (b) **SSR apps** (zine =
   SvelteKit `adapter-node`) running in VMs. Their caching stories differ.

The team is **middleman / lock-in averse** — a first-class axis, not a footnote.

## Options considered

### A. Managed CDN in front (Bunny.net)
A pull-zone CDN terminates HTTP/2-3 with browsers and pulls over HTTP/1.1 from the
gateway — **zero gateway changes, no risk to DNS-01 cert issuance** (research H4).
Bunny is the low-lock-in fit: CNAME-only, BYO-cert (origin keeps its own LE cert),
flat ~$0.01/GB (**~$10/mo @ 1 TB, ~$50/mo @ 5 TB**), 119 PoPs, HTTP/3, free WAF/DDoS;
exit = re-point a CNAME.
- **Gives:** h2/h3 + edge caching + **geo**, for ~days of work and no code.
- **Costs:** a middleman (though the shallowest — CNAME swap to leave); the edge
  terminates client TLS (structural to any TLS CDN). One unverified assumption:
  HTTP/1.1-origin pull compatibility (architecturally near-certain; needs a live test).

### B. Offload static assets to IdentiKey Sites
Publish SvelteKit's fingerprinted `_app/immutable/*` output to the existing
content-addressed **Sites** store (`mix mjolnir.sites.publish` + `sites/publisher.ex`
already exist). Those assets then serve from host disk with **no VM in the path**; only
the SSR HTML hits the VM.
- **Gives:** host-side "asset caching" by *reusing a subsystem we already built* — no
  middleman, no gateway rewrite. Makes the origin's static surface a pure static store
  (which also makes any future CDN's job trivial).
- **Costs:** a build→publish step in the deploy pipeline; **no geo**; only helps the
  static surface, not SSR HTML. Composes *with* A rather than competing.

### C. Rewrite the gateway into a caching HTTP proxy ("real HTTP edge")
Replace the byte-pipe with a hyper HTTP/1+2 terminating proxy + a cache layer
(key on host+path, honor cache-control/etag, memory+disk tiers, eviction, revalidation,
explicit Upgrade/websocket handling).
- **Gives:** h2 + self-hosted caching, full sovereignty, no middleman.
- **Costs:** **weeks of work + a new bug/attack surface on the one component every
  request flows through**; delivers a *subset* of A (no geo); DDoS and PoP-breadth
  ceiling is on us. The research's self-host row confirms "HTTP/2 + host cache" is a
  real but *incremental* win, not a differentiated one.

### D. Status quo
Keep the byte-pipe; no h2, no caching. Given the 7s is gone and origins are fast, there
is **no active pain** today.

## Decision

1. **Reject C (the gateway rewrite) for now.** It is the most expensive option, delivers
   the least differentiated benefit (no geo), and puts risk on the all-traffic component
   to solve a problem that is no longer urgent. Revisit **only** if we commit to *zero*
   third-party middleman **and** go multi-host wanting a caching edge on each node we own
   — a deliberate future decision, not a next step.
2. **Adopt A (Bunny in front) as the sanctioned path to h2/h3 + caching + geo — when a
   trigger justifies it**, not preemptively. Triggers: measurable geographic latency for
   real users, VM asset-serving load, or renewed "images slow in email." It needs no
   code and is reversible by a CNAME.
3. **Steer the static surface toward B (Sites).** Independent of A, prefer host-served
   Sites over VM-served static assets. For SSR apps like zine, publishing immutable
   assets to Sites is the no-middleman way to keep the VM out of the asset path — and it
   composes with a future CDN (CDN in front of a pure static origin is ideal).
4. **Keep the byte-pipe gateway** as the local/Iroh router + TLS terminator. Do not grow
   it into an HTTP server.

Net: **status quo now**, with A as a documented, ready-to-pull lever and B as the
preferred direction for static content. We buy the big user-facing wins (h2/h3, geo,
caching) from a swappable CNAME layer, not a core rewrite.

## Consequences

- No engineering committed to an edge rewrite; the gateway stays simple and reliable.
- A CDN decision becomes a business/ops toggle (pick Bunny, point a CNAME) gated on a
  real trigger, with KeyCDN as the drop-in runner-up and Cloudflare as the cheapest-at-
  scale option if we ever accept full DNS delegation.
- Static content increasingly flows through Sites, reinforcing that subsystem and
  keeping VMs for dynamic work only.
- **Spikes required before pulling lever A** (from the research's flagged unknowns):
  (1) live test of Bunny HTTP/1.1-origin pull against `mjolnir-gateway`; (2) measure
  real traffic geography and the asset:SSR byte ratio to size the win and cost;
  (3) a CDN-purge-on-publish hook for Sites HEAD updates.

## Follow-ups
- File a spike bead for the Bunny HTTP/1.1-origin pull test + traffic-geography
  measurement before committing to a CDN.
- Consider a `zine → adapter-static`/immutable-asset publish-to-Sites experiment as the
  first instance of decision (3).
