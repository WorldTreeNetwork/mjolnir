# Licensing and components: consumer vs server

**Status:** Position. Not an ADR. Not a SHALL — the SHALL is the
[LICENSE](../../LICENSE) / [NOTICE](../../NOTICE) pair.
**Date:** 2026-09-08
**Copyright:** World Tree Network Foundation

Mjolnir moved out of Identikey, Inc. into the World Tree Network
Foundation. World Tree LLC sells mesh hardware. This note is the cut
we are holding: **AGPL on the host product, MIT on the consumer
client**, and why that split is the one that keeps mini-hosters free
to plug in a box.

---

## Why AGPL on the server

Mjolnir is a network service. The interesting work — spawn a
checkpointable Linux microVM, inject secrets, offer a PTY, multiplex
tmux, speak Iroh — happens on a machine someone leaves on.

AGPL-3.0-or-later (section 13) is the anti-enclosure clause: if you
modify the host and offer it as a network service, you share the
source with the people who use it. That is the point. A hyperscaler
cannot wrap Mjolnir, keep the fork closed, and starve the people
running boxes.

What AGPL does **not** do:

- It does not stop anyone running the unmodified software.
- It does not stop anyone selling hardware that runs it.
- It does not make a mini-hoster file paperwork. Unmodified AGPL, with
  this repo as the source offer, is the whole duty.

World Tree LLC selling mesh nodes (Iroh-addressed base layer, radios
that carry local services as far as the backhaul reaches) is a
hardware business. The Foundation holds the copyright. The LLC is not
the licensor. Lightning Mesh already documents the same split and
offers a commercial exception for OEM/SaaS that cannot live with
section 13; Mjolnir does not need that instrument to sell boxes.

---

## Why MIT on the CLI

The consumer installs `mj` (also `mjolnir`) on a laptop, a phone
build, an IDE, Papyrus. That binary talks *to* the fabric. It is not
the fabric.

MIT means:

- Homebrew / crates.io / distro packages can ship `mj` without AGPL
  infection.
- Other apps can link `mjolnir-api` (Papyrus already does).
- A site can vendor the client without becoming an AGPL network
  service.

The CLI is how you spawn, `exec`, `connect` (real PTY; `--session`
attaches tmux so reconnects and extra humans converge on one
terminal), `secrets set` (names only on list; values injected at VM
spawn as env vars), and talk Iroh tickets across NAT.

---

## The crate cut (load-bearing)

AGPL copyleft follows linking. If the MIT CLI depended on an AGPL
crate, the CLI would not be MIT.

| Component | Path | License | Role |
|---|---|---|---|
| `mj` CLI | `native/mjolnir_client` | MIT | Consumer. Spawn, exec, PTY, tickets, deploy, secrets names. |
| API client | `native/mjolnir_api` | MIT | Shared HTTP + OIDC store. CLI and Papyrus. |
| Wire protocol | `native/mjolnir_protocol` | MIT | Vsock / PTY framing. Both sides speak it. |
| Elixir orchestrator | `lib/mjolnir` | AGPL-3.0-or-later | Host: CH, BTRFS, TAP, Forge, Sites, secrets escrow. |
| Guest agent | `native/mjolnir_guest_agent` | AGPL-3.0-or-later | Injected into every VM: exec, PTY, tmux, LUKS secrets → env, Iroh. |
| Gateway | `native/mjolnir_gateway` | AGPL-3.0-or-later | Host HTTP / Iroh edge. |
| Blob door | `native/mjolnir_blob_door` | AGPL-3.0-or-later | Host sidecar. |
| Biscuit face | `native/mjolnir_biscuit` | AGPL-3.0-or-later | Host mint/verify CLI the BEAM calls. Not linked by `mj`. |
| Bootstrap / systemd / Forge | `scripts/`, `systemd/`, `forge/` | AGPL-3.0-or-later | How you stand a node up. |

Protocol and api **must** stay MIT. The guest agent **must** stay
AGPL: it is the host product living inside the guest (PTY, tmux,
secrets). A consumer of a VM is not relicensing the agent; the
operator who runs the host is.

Do not copy AGPL sources into MIT crates. Iroh ALPN strings and wire
constants are not a license problem. Secret-handling code in the
agent is.

---

## Consumer vs operator, in the product

**Consumer** (MIT client, any OS):

- Install `mj`, `mj login`, spawn a VM on someone else's node or
  yours.
- Interactive shell is a real PTY. `mj connect --session NAME`
  attaches tmux inside the guest so drop-and-retry and extra peers
  share one session.
- Secrets: `mj secrets set` stores names on the host; at spawn the
  guest maps them to env vars (`DATABASE_URL`, keys, …). Plaintext
  lands on tmpfs (`/run/mjolnir/secrets.env`), not the snapshot.
  Host-blind inject can go client → Iroh → guest and never touch
  Elixir. See [secrets-architecture.md](../secrets-architecture.md).
- Reach a VM from anywhere Iroh can NAT-traverse, or on the local
  mesh by whatever name the radios already know.

**Operator / mini-hoster** (AGPL host, Linux):

- Plug in a mini-PC (today) or, when ARM ships, a Raspberry Pi.
- Bootstrap installs KVM + BTRFS + Cloud Hypervisor + the
  orchestrator. The box becomes an Iroh-addressed compute node.
- Any service can run in a VM on that box, including GPU passthrough
  when the host has IOMMU (see
  [hardware-requirements.md](../hardware-requirements.md) §5).
- Local services are reachable wherever the Lightning Mesh backhaul
  radios reach; Iroh is the overlay when you are off the island.

The two roles can be the same person. The licenses stay different
because the *artifacts* are different.

---

## Mini-hosters, Raspberry Pi, honesty

The north star is: anyone puts up a box. The honest ship-today host
is an **x86_64 mini-PC** with VT-x/AMD-V, `/dev/kvm`, BTRFS, ≥ 16 GB
RAM, NVMe. N100/N305-class machines work.

**Raspberry Pi is a goal, not a current capability.** The guest agent
and rootfs pipeline target `x86_64-unknown-linux-musl`. Cloud
Hypervisor has ARM64 upstream; we do not test it. Pi 5 has KVM; SD
cards are a bad BTRFS home — USB/NVMe storage would be required.
Document the gap; do not advertise a SKU we cannot boot.

GPU: any computer that *is* the host and has an isolatable IOMMU
group can pass a GPU into a VM. Most mini-PCs cannot; a discrete-GPU
NUC-class box can. Clients on the mesh reach that VM over Iroh. They
do not need the GPU locally.

---

## Foundation vs LLC

| Entity | Owns / does |
|---|---|
| World Tree Network Foundation | Copyright, AGPL/MIT publication, `duke@worldtree.io` |
| World Tree LLC | Sells mesh nodes (radios + Iroh base layer). May sell or image mini-PCs. Hardware sale ≠ software relicensing. |

Do not put the LLC on the copyright line. Do not write license text
that makes buying a node a software EULA.

IdentiKey as a *product* name (Sites, identity subsystem) stays.
Identikey, Inc. as owner does not.

---

## Sister projects (same Foundation)

Same rule: **network service → AGPL; consumer protocol/CLI/dev tool →
MIT (or keep a more-permissive license already granted).**

| Repo | Cut |
|---|---|
| [lightning-mesh](https://github.com/WorldTreeNetwork/lightning-mesh) | Already AGPL-3.0-or-later + commercial + CLA. Operator daemon and `meshctl` are both AGPL (you run the mesh). |
| [MetaCoding](https://github.com/WorldTreeNetwork/MetaCoding) | MIT. Local-first dev tool, not a network service. npm name `@identikey/metacoding` is a product remnant — renaming is a breaking publish, not a license issue. |
| [Dreamball](https://github.com/WorldTreeNetwork/Dreamball) | Protocol / WASM / CLI / browser: MIT (consumers author types). `dreamball-server`: AGPL. AGPL on the WASM core would infect every ball in a browser. |
| [Conduit](https://github.com/WorldTreeNetwork/Conduit) | **Apache-2.0, and it stays.** The `conduit/` crate is a bring-your-own-host library; embeddability is the product (Synapse is AGPL and cannot be linked into an app). AGPL on the library would undo that. A later AGPL-only `conduit-server` binary is optional and is not the library. |
| Artifactory | Hosted pipeline UI: AGPL. |
| dreamball0-blender | Viewer / assets: MIT. |

Repos in this working tree that are **not** Foundation projects
(Morphist `aspects`, StartupCentralAZ `start-console-backend`,
`epinoia`, …) are out of scope.

---

## CLA

Inbound contributions need the CLA in `CLA.md` (same shape as Lightning
Mesh; Foundation is "the Project"). That is what lets the host stay
AGPL, the CLI stay MIT, and a commercial OEM/SaaS exception exist for
the host. Hardware sales of unmodified AGPL still do not require that
exception.

---

## What must stay true in the docs

- Clone URLs that 404 are worse than a still-Identikey GitHub until
  the org transfer lands. See `docs/transfer/mjolnir-to-wtnf.md`.
- Pi / ARM is a goal. Mini-PC is the SKU.
- Secrets become env vars inside the guest; they never enter the
  snapshot.
- `mj connect` is a PTY; tmux is how sessions survive disconnect.
- Mini-hosters run AGPL software; they are not asked to buy a
  license from the LLC.
