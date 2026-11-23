1. Pin a disabled-by-default service whose enable, failure, disable, and redeploy paths have observable listener and firewall outcomes.
2. Pin one authentication gate for WebTransport and Iroh; refuse missing, malformed, expired, wrong-key, and wrong-audience credentials before media or discovery access.
3. Pin publish/read authority and canonical owner-prefix isolation now; refuse any interim open mode while room-token minting is deferred.
4. Pin credential purpose and trust roots explicitly against edge-auth; refuse implicit conversion of login credentials or Iroh peer identity into relay authority.
5. Pin exact upstream revisions and the supported wire contract; refuse dependency defaults that silently add public access, discovery, or ticket-driven outbound dialing.
6. Pin a certificate for the configured hostname, matching private key, validity checks, and renewal behavior; refuse self-signed fallback or serving after expiry.
7. Pin HTTP-01 issuance without new routing apexes, preserving site-certs lookup/list/renewal semantics and keeping PEMs on the host.
8. Pin gateway-to-relay key transfer with least privilege, private staging, coherent certificate/key replacement, and failure retention; refuse exposing other gateway or identity keys.
9. Pin independent unit/deploy ownership, bounded process resources, and negative tests on both transports; refuse controller restarts or changes to guest UDP publishing as collateral effects.
10. Tradeoff: host termination enables practical browser fan-out but exposes media to the host; state that trust boundary plainly and do not imply end-to-end encryption.
