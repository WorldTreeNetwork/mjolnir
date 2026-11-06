1. Pin the proxy class to its base image; disabling Iroh on an ordinary guest must not change that guest's network policy.
2. Pin the proxy unit as the egress boundary, with loopback and exactly 10.200.0.1 allowed; absence of a default route alone is insufficient confinement.
3. Refuse any acceptance that cannot distinguish a working root public connection from a blocked connection in the actual proxy unit's cgroup.
4. Require no default route, exactly the loopback resolver, the host /32, and a successful TCP connection to host port 4000 after boot and repair.
5. Preserve ordinary network setup, the ordinary health probe, and ordinary shell relay behavior, including the ordinary enable_iroh=false case.
6. Persist base_image and the literal false flag through the supported reboot/resume path; distinguish a missing flag from a false one.
7. The reboot route returns an acknowledgement, not a VM representation; require ok, rebooted, and guest_healthy there, then inspect GET /api/vms/:id.
8. Require the live detail's enable_iroh=false and present empty ticket and iroh_addr fields after reboot; missing fields cannot prove absent publication.
9. Refuse a green checker on missing inspection, failed cgroup entry, nonzero guest exit, inactive unit, route substring matches, or cleanup without invocation ownership.
10. Tradeoff: accepting a base-image class and reboot-only lifecycle keeps this node small, but requires explicit implementation tests for class-aware health rather than treating old-release spike evidence as that proof.
