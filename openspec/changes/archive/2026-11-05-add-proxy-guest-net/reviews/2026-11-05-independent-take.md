1. Pin proxy-class identity independently of a caller remembering enable_iroh=false; ordinary guests must retain their current defaults.
2. Pin the class across boot, resume, restore, and health repair so no lifecycle path silently chooses ordinary networking.
3. Require the proxy setup script to establish only the host /32 route and remove stale default routes and public resolvers idempotently.
4. Refuse a proof based only on absent IPv4 default routing: the process boundary must deny other reachable addresses, including IPv6 and other guests.
5. Pin enable_iroh=false before the guest's one-shot startup decision; preserve presets::N0 for ordinary guests.
6. Require class-aware L2 health that recognizes intentional isolation and cannot heal it into public connectivity.
7. Refuse the unmodified stock unit as success: prove actual proxy startup, usable journal storage, and permitted host-API connectivity together.
8. Pin when confinement becomes effective and make failure to install it fail closed before the proxy serves traffic.
9. Require positive loopback/host probes and negative public/alternate-address probes under the actual proxy confinement, repeated after repair and resume.
10. Tradeoff: a dedicated image/unit can minimize ordinary-guest changes, but its policy and lifecycle persistence need stronger evidence than spawn-time flags alone.
