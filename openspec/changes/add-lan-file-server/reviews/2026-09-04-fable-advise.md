# Advise — add-lan-file-server (architecture, fable)

> **ADVISE:** send-back
> **READER:** fable-5.1-arch-review
> **SPAWN:** .spawns/advise-add-lan-file-server-fable-1788535585-453934-6ae06aea

Change: `add-lan-file-server` (bead `mjolnir-h2fp.2`, ACTIVE BUILD).
Rigor: architecture. Density: lean. Author family: Grok. Second
other-family reader. The critic send-back at
`reviews/2026-09-04-advise.md` stands untouched. Do not fold. Do not
`act`. No product code.

---

## Blind take (written before design.md / tasks.md)

From Why, `specs/lan-files/spec.md`, `blob-store` §door bind, and
`docs/guide/host-sidecars.md` only.

1. **Pin:** the share is one Mjolnir guest running the Recrypt HTTP
   (recrypt-server or equivalent); the door stays `10.200.0.1:7222`;
   the guest never holds B2 keys. Bytes go door-ward, caps and index
   live in the guest.
2. **Pin:** "published onto 192.168.0.18" is a host-side forward,
   LAN addr:port → guest TAP IPv4:port. That port is not 7222 and
   not the gateway's 443. It needs FORWARD allow LAN→TAP plus the
   return path; TAP guests are `/32` behind the host.
3. **Pin:** the ULA leg cannot be a TAP address. `Mjolnir.Network`
   is IPv4-only (`10.0.0.0/8`). Publishing on `fd01:…` therefore
   means a host userspace proxy listening on `[fd01::x]:port` and
   dialing the guest v4, not DNAT66 (nft cannot NAT64/46 a v6
   listener into a v4 TAP). Say which.
4. **Refuse:** a second NIC, bridge, or macvtap into the guest on the
   LAN. That is a new network mode outside the host-gateway model and
   Reconcile/Cleanup do not know it.
5. **Refuse:** any FORWARD or DNAT rule whose destination is
   `10.200.0.1:7222`. The publish path must not make the door
   LAN-reachable by accident.
6. **Pin:** one `aud` for the identikey-auth challenge across all
   three reach paths (LAN v4, ULA v6, `.mesh` name). If `aud` is the
   address, a Response minted on one path fails or replays on
   another. Use a service id, not an IP.
7. **Pin:** cap issuance and durability. Who signs the
   `Capability(h → f, read)` — the uploader's key in a client, not a
   key in the guest. Caps and the hash index are guest state on a
   `@vms/<uuid>` subvolume; a kill/respawn loses them unless the
   store is snapshotted or lives on a durable mount.
8. **Pin:** the share VM's TAP IP is hash-of-UUID. A respawn is a new
   UUID → new IP → dead forward rule. Either a stable slug→IP
   binding or the proxy resolves the guest by name at start.
9. **Pin:** the publish rules (DNAT, proxy unit, UFW) are Forge
   declarations (`iptables`, `ufw_nat`, `systemd_unit`), not hand-run
   commands. A hand-run rule is drift on the next plan.
10. **Tradeoff:** meshd publish on the attached router keeps
    `mjolnir-meshd` off this host, so `.mesh` discovery is
    out-of-band on another box. Acceptable for v1, but the record
    must point at the ULA this host actually holds and on which
    interface. Name the interface.

---

## Compare (after design.md / tasks.md / proposal.md / steer.md)

Checked against `identikey-auth-challenge-v1.md` (`aud` at :98,
:105, :170; §5 fingerprint at :140-150), `lib/mjolnir/network.ex`
(`allocate_ip/1` :150, SHA-256 of `vm_id` into `10.192/10`, IPv4
only), `lib/mjolnir/gateway/routes.ex` (`resolve_app_vm/2` :311),
`lib/mjolnir/forge/resource/ufw_nat.ex`, and `ip -br addr` on this
host (the laptop the proposal names).

How the design answers the blind take:

- **(1) Guest Recrypt HTTP, door TAP-only, no B2 in guest.**
  Answered. "Where bytes live" and "How LAN sees it" match; spec
  copies the living `blob-store` door bind. Keep.
- **(2) Host-side forward, dedicated port.** Half. "DNAT or a host
  proxy" is named; port is not. Leaving DNAT-vs-proxy to `h2fp.3`
  is fine at this density (agree with critic). Port is an
  implementer note as long as it is not 7222 on a wildcard bind.
- **(3) ULA leg is a host proxy, not a TAP v6.** Implicit only.
  Design says "wifi RA" for the ULA and "host proxy" as one option.
  Since TAP is v4-only, the v6 leg *must* be a host process or a
  v6→v4 proxy; DNAT alone cannot do it. Design should say so in one
  clause. Minor.
- **(4)(5) No bridge; no forward to the door.** Answered in
  "Contrast rejected" (no L2 bridge, no host-sidecar LAN bind of
  the door). Keep.
- **(6) One `aud` across three reach paths.** Not answered.
  Design: "`aud` = this share." Spec: "challenge whose `aud` is
  this service." The protocol says `aud` is a free-form string
  naming the service (`:98`, `:105`) and is checked for equality
  (`:170`). With a LAN v4 address, a ULA, and a `.mesh` name, an
  implementer who derives `aud` from `Host` or from the bound
  address gets three audiences for one share. Under an L7 proxy the
  `Host` seen by the guest is the proxy's. This needs a pin: `aud`
  is one stable service identifier, not a network locator. Owed.
- **(7) Cap issuance and durability.** Not answered in design;
  the critic's Major 1 and "What's Missing" cover durability. I
  endorse and add nothing.
- **(8) Respawn changes the TAP IP.** Not answered. `allocate_ip/1`
  is SHA-256 of `vm_id`; Reconcile resumes the same `vm_id` across
  an Elixir restart, so DNAT survives `just deploy`, but `mj kill`
  plus respawn is a new address. The gateway already solves this
  by resolving `app_name → service_vm_id` from the registry
  (`routes.ex:311`). Implementer note for `h2fp.3`: a proxy that
  resolves by name, or a DNAT rule re-rendered from the registry.
  Not a box.
- **(9) Publish rules are Forge declarations.** Not in design;
  critic Minor 2 covers `ufw_nat`. Add: the v6 proxy is a
  `systemd_unit` declaration. Implementer note.
- **(10) Name the interface and the address.** Not answered, and
  the host disagrees with the proposal. See Critical 1 below.

Steelman for the author: steer closed every product fork and the
design is right on all of them. The two things below are not
product forks. They are the seam between "published" and
"reachable", which the spec's own scenarios ("Ethernet client
fetches", "Mesh ULA is reachable") make load-bearing.

---

## Critical (blocks accept)

1. **The publish addresses are a link state, not a fact about the
   host. The design binds to them as facts.**

   Observed on this host, 2026-09-04, via `ip -br addr`:

   | Interface | State | Address |
   |---|---|---|
   | `wlp191s0` (wifi, SSID `NETGEAR05-5G`) | UP | `192.168.0.19/24`, GUA `2601:…` |
   | `enp196s0f0u2u2` (USB Ethernet) | DOWN | none |
   | any | — | no `fd01:d28c:7e4a::/48` address, no `fd01` route |
   | `dummy-mjolnir` | UP | `10.200.0.1/32` |

   The proposal states "`fd01:d28c:7e4a` on wifi, `192.168.0.18` on
   Ethernet". Right now Ethernet is down, wifi is on a home AP at
   `.19`, and the ULA is absent. Both publish targets exist only
   when this laptop is plugged into that Ethernet *and* joined to
   the mesh SSID. That is normal for a laptop. It is not addressed.

   Also: `fd01:d28c:7e4a` is a `/48` prefix in every document
   here, never an address. The design says the ULA arrives by
   "wifi RA", i.e. SLAAC. NetworkManager's default is
   stable-privacy plus temporary addresses. `meshd publish --ip`
   records one fixed address. Which one is published, and is it
   the stable one, is unstated.

   Why this is architecture and not act: the spec requirement
   "LAN and mesh ULA can reach the guest" has no fail-mode. The
   path of least resistance when a bind address is missing is to
   bind `0.0.0.0` / `::` "until the address shows up". That is the
   exact failure the living `blob-store` forbids for the door, now
   reproduced on the publish path, and it silently exposes the
   share on the Comcast GUA and every Docker bridge this host
   carries (`br-*`, `docker0`, `172.16/22`, `172.17/16`).

   Fix (design.md, a short paragraph; spec, one scenario):
   - Publish binds by **interface**, not by address: DNAT matched
     on `-i <iface>`, or a proxy using `SO_BINDTODEVICE` /
     `IP_FREEBIND` / `net.ipv6.ip_nonlocal_bind` scoped to the two
     named interfaces.
   - When the interface has no address, the publish path waits or
     fails; it SHALL NOT fall back to a wildcard or to the GUA.
     Add a scenario "Ethernet unplugged" mirroring the door's
     "Dummy address missing".
   - Name the ULA address, not the prefix, and pin it as the
     stable-privacy address or an `ipv6.token`. That is the value
     `h2fp.4` hands to `meshd publish --ip`.
   - Keep the concrete addresses as examples (critic Minor 3).

---

## Major (rework before act)

1. **`aud` is unpinned across three reach paths.**

   `identikey-auth-challenge-v1.md:98` defines `aud` as "the
   service/identity this proof is FOR"; `:170` checks it for
   equality. The design and the spec say only "this share" /
   "this service". The share is reached as `192.168.0.18:p`,
   `[fd01:…]:p`, and `<name>.<node>.mesh:p`, possibly behind an L7
   proxy that rewrites `Host`. Three locators, one service.

   Fix: one sentence in `design.md`: `aud` is a fixed service
   identifier chosen by the share (a URN or the share's own
   fingerprint), the same on every path, never derived from
   `Host`, bound address, or port. Spec scenario "Claimant holds
   the key" gains "AND `aud` equals the share's service id
   regardless of the address the client used".

---

## Endorsed from the critic send-back (`reviews/2026-09-04-advise.md`)

- **Critical 1, fingerprint join.** Verified. §5 (`:146-149`)
  says identikey-auth fingerprints are "a distinct namespace from
  recrypt's raw-Ed25519 fingerprints by construction". The spec
  scenario "Cap permits read" uses one `f` for both. Stands.
- **Major 1, unmodified `recrypt-server` is not the share.**
  Stands. My blind take (7) landed one layer above it: I asked who
  issues the cap and where it lives; the critic showed the shipped
  binary answers neither and serves GET publicly.

No duplicate boxes for these two. The owed boxes on `tasks.md`
from this review are Critical 1 and Major 1 above only.

---

## Minor / implementer notes for `h2fp.3` and `h2fp.4`

- v6 leg is necessarily a host process; TAP has no IPv6
  (`network.ex`). Say it once in design.
- Respawn moves the TAP IP (`allocate_ip/1` is SHA-256 of
  `vm_id`). Resolve the share VM by name like
  `Gateway.Routes.resolve_app_vm/2`; do not hand-write the IP into
  a DNAT rule.
- Publish rules live as Forge declarations (`ufw_nat` for DNAT,
  `systemd_unit` for a proxy, `iptables` for the FORWARD allow).
  Hand-run rules are drift on the next plan.
- Publish port must not be 7222 on any non-TAP address; the door
  lives there on `10.200.0.1`.

---

## Verdict

Send-back. Product pins are right and steer-closed; keep all of
them. What is missing is the seam the spec's own reach scenarios
depend on: the bind targets are transient link state with no
fail-mode, the ULA is a prefix not an address, and `aud` has no
stable value across three locators. Plus the critic's two, which
stand.

Upgrade to accept: close the two owed boxes here and the two from
the critic. Nothing else in this review gates.
