1. Pin the selected edge's stable public XID through explicit trusted provisioning; DNS and discovery may supply addresses only.
2. Require a verifiable authorization chain from that stable identity to each operational public key, with purpose, validity, and edge binding.
3. Keep stable private material out of ordinary session handling; explain how fresh operational keys gain authorization while the anchor is offline.
4. Persist operational keys across restarts; distinguish first provisioning from missing, corrupt, or rolled-back established state and refuse silent identity replacement.
5. Enforce private files at 0600 and their directory at 0700 outside the actual BTRFS data tree, including temporary files and configured path aliases.
6. Make key publication and activation crash-consistent so a restart cannot advertise one key while signing with another.
7. Define rotation overlap against capability lifetime, proof validity, clock skew, and verifier cache lifetime, including behavior after retirement.
8. Bound compromise recovery: retiring a signing key must eventually stop its authority, and a stolen operational key must not authorize arbitrary successors.
9. Preserve sites-token scope, localhost handling, JWT verification, and hosted /term authentication; the edge key owner must not silently introduce a new auth lane.
10. Accept the tradeoff of host-file operational keys for autonomous service, while requiring explicit root custody/recovery and acknowledging that host compromise exposes online authority.
