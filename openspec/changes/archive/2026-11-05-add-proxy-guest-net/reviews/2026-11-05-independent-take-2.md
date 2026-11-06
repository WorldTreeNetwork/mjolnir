1. Pin the proxy class to an explicit, durable base-image identity; disabling Iroh alone must never select restricted networking.
2. Pin proxy creation and resume to false Iroh configuration before the guest can publish a relay; refuse an explicit true request.
3. Preserve the existing false-versus-missing distinction through API options, build_running_record/1, and resume_opts/1.
4. Pin the proxy network to no default route, no public resolver, and a usable host-API /32, including after repeated configure_network calls.
5. Make GuestNetwork inspect isolation as well as reachability: Health.do_heal skips every check whose probe reports ok.
6. Refuse a healthy verdict for route/resolver drift, a missing host /32, a failed host TCP connect, or absent inspection/connect tooling.
7. Treat the api-proxy unit as the remote-address boundary; a failed public connect with no route does not establish unit confinement.
8. Require paired root-versus-unit probes with a working default route, successful allowlisted connects, and fatal cgroup/inspection/assertion failures.
9. Keep ordinary guests, including ordinary guests with Iroh disabled, on the stock script and ordinary health behavior; retain N0 when Iroh is enabled.
10. Tradeoff: an image-selected class avoids a new holder class but couples host classification to image contents; require a concrete selector and reproducible evidence without production boot or restart.
