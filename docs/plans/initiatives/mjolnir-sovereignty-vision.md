# Mjolnir: A Sovereign Computational Fabric

*The right to compute on your own terms.*

---

## The Problem We Refuse to Accept

The internet was designed as a decentralized network of peers. What we got instead is a feudal system. A handful of hyperscale cloud providers — AWS, Azure, GCP — control the computational substrate on which nearly all modern software runs. When you deploy to the cloud, you are a tenant on someone else's land. Your data lives in their data centers, subject to their terms of service, their pricing whims, their compliance with government subpoenas you will never see. Your workloads can be terminated, your accounts suspended, your years of infrastructure investment rendered inaccessible — all by a single entity's unilateral decision.

This is not an abstract concern. In 2026, over $100 billion is being committed to sovereign AI compute infrastructure globally, driven by the recognition that whoever controls the compute controls the outcome. Sixty-one percent of Western European CIOs say geopolitical factors are increasing their reliance on local providers. The EU Data Act, DORA, and a cascade of national sovereignty regulations are forcing organizations to answer a question they have long avoided: *who actually controls our computing?*

The answer, for most, is uncomfortable.

Mjolnir exists because we believe the answer should be: *you do.*

---

## What Mjolnir Is

Mjolnir is a distributed computational fabric for spawning, checkpointing, and orchestrating Linux microVMs. It provides the primitive operations of sovereign compute — create an isolated execution environment, run code in it, snapshot its state, restore it later, move it elsewhere, connect it to peers — without requiring permission from any central authority.

At its technical core, Mjolnir is an Elixir/OTP application that orchestrates microVMs through Cloud Hypervisor (the active default; Firecracker is deprecated), uses BTRFS copy-on-write reflinks for instant filesystem cloning, communicates with guest agents over vsock, and integrates Iroh for NAT-traversing peer-to-peer connectivity. Each VM runs a Rust guest agent that provides command execution, PTY shell access, an agent SDK for in-VM applications, and inter-VM messaging.

But the technical description misses the point. Mjolnir is not a product. It is infrastructure for a different kind of internet — one where computation is sovereign, portable, and addressable by cryptographic identity rather than by the IP address your cloud provider assigned you.

---

## The Principles

### Sovereignty Is Not Optional

Digital sovereignty is the right of individuals, communities, and organizations to maintain control over their own computing infrastructure. Not "sovereignty" as enterprise marketing jargon for "we will run the same cloud in your jurisdiction." Real sovereignty: you own the hardware, you run the software, you control the keys.

Mjolnir is designed from the ground up for self-hosted deployment. A single Linux server with KVM support, a spare disk for BTRFS, and an Elixir runtime is a complete Mjolnir node. There is no control plane you do not own. There is no license server to phone home to. There is no vendor who can revoke your access. The orchestrator, the hypervisor, the guest agent, the networking layer — every component runs on machines you control.

This is not a limitation. It is the entire point.

### Computation Deserves Preservation

Brewster Kahle, founder of the Internet Archive, has argued for decades that we must "lock the web open" — that the values of privacy, free expression, and universal access to knowledge must be embedded in the architecture of our systems, not merely promised by their operators. His observation that "code is law" carries a corollary: if we build infrastructure that permits censorship and surveillance by design, we will get censorship and surveillance.

The Internet Archive created a Wayback Machine for the web. Mjolnir aspires to create something analogous for computation.

Every Mjolnir VM runs on a BTRFS filesystem that supports instant, space-efficient snapshots through copy-on-write reflinks. A snapshot of a 2GB rootfs is created in milliseconds and initially consumes zero additional disk space — only divergent blocks are stored. This is not backup; it is temporal addressing. Any moment of a VM's computational state can be captured, named, restored, cloned, or transferred.

The implications compound. A researcher can checkpoint an experiment at every significant state transition and later branch from any point. A developer can snapshot a working environment before a risky change and restore it if things go wrong. An AI agent can save its progress, go dormant to conserve resources, and be awakened later — potentially on a different machine — with its full state intact. The dormant VM registry already implements this pattern: when a VM signals "done," Mjolnir snapshots it, stops the hypervisor to free resources, and restores it automatically when a new message arrives. Computation becomes something that can be paused, preserved, and resumed — not a fleeting process that vanishes when the power goes out.

This aligns with the Internet Archive's ethos of preservation as a public good. Computation should not be ephemeral by default. It should be ephemeral by choice.

### Identity Without Permission

The web's current identity infrastructure is a dependency chain that terminates in centralized authorities. TLS certificates come from certificate authorities. Domain names come from registrars. User accounts come from identity providers. At every layer, someone else decides whether you are who you say you are.

The PGP web of trust demonstrated, decades ago, that decentralized identity is possible — that trust can be established through peer-to-peer attestation rather than hierarchical authority. PGP's limitations were real (key management was onerous, email-centric identities depended on centralized infrastructure), but its core insight was sound. Self-sovereign identity, now formalized through Decentralized Identifiers (DIDs) and Verifiable Credentials, carries this insight forward: individuals should control their own identifiers, credentials should be cryptographically verifiable without contacting their issuer, and no central registry should be required.

Mjolnir embraces this model. Each VM with Iroh enabled generates or loads a cryptographic keypair (Ed25519) that serves as its identity on the network. The public key — the Iroh node ID — is the VM's address. It does not depend on DNS, on IP allocation, on cloud provider metadata. It is a self-certifying identifier: if you can complete a cryptographic handshake with a node, you know you are talking to the entity that controls that private key. No certificate authority required. No domain registrar in the loop. No identity provider that can lock you out.

This keypair is persisted at `/etc/mjolnir/iroh.key` inside the VM. When a VM is snapshotted and cloned, Mjolnir deletes the key from the clone by default — ensuring each new VM gets a unique cryptographic identity — but preserves it when explicitly requested, allowing a restored VM to retain its network identity across checkpoint/restore cycles.

The vision extends beyond individual VMs. In a fully realized Mjolnir network, agents and VMs authenticate each other through their cryptographic identities, forming webs of trust without central coordination. A VM can prove it was spawned by a particular orchestrator, an agent can prove it holds credentials issued by a particular authority, and all of this happens through mathematics rather than through deference to institutions.

### The Network Is the Fabric

The decentralized web movement — from IPFS to libp2p to Hypercore — has built remarkable infrastructure for decentralized storage and networking. Content-addressed data, peer-to-peer file transfer, distributed hash tables, gossip protocols — these primitives are mature and battle-tested. What the dweb has largely not addressed is decentralized *compute*. You can store a file on IPFS and retrieve it from any peer. But where do you *run* the program that processes that file?

This is the gap Mjolnir fills.

Iroh, from n0 Computer, provides the networking substrate. Built in Rust atop QUIC, Iroh offers content-addressed blob transfer using BLAKE3 verified streaming, peer-to-peer connections that traverse NATs via relay servers, and a protocol-agnostic endpoint model where connections are routed by ALPN (Application-Layer Protocol Negotiation) rather than by port numbers. Mjolnir's guest agent uses Iroh to accept incoming shell connections and TCP forwarding sessions from anywhere on the internet, addressed only by the VM's cryptographic node ID.

The result is that a Mjolnir VM is reachable by its identity, not by its network location. A VM running behind a home router's NAT, on a Vultr VPS, or on a Raspberry Pi in a closet is equally addressable. The operator does not need a static IP, a domain name, or a cloud load balancer. They need only to share their node ID — a 52-character z32-encoded string — and any peer with Iroh can connect.

This property is foundational for the mesh topology Mjolnir is designed to grow into. Today, Mjolnir nodes are single-server deployments. The architecture transition plan charts a path toward multi-node clusters using BEAM distribution (libcluster + Syn for gossip-based node discovery, :pg for pub/sub process groups), with BTRFS send/receive for cross-node snapshot replication. In this topology, VMs can migrate between nodes, snapshots can be replicated for redundancy, and the cluster presents a unified computational surface — all without a centralized coordinator.

The long-term vision is a heterogeneous mesh of Mjolnir nodes, each sovereign, each contributing compute capacity to a shared fabric, each communicating through Iroh's peer-to-peer overlay. Not a blockchain. Not a marketplace. A commons.

---

## The Agent Compute Fabric

The convergence of AI agents and sovereign compute is not a coincidence. It is a necessity.

In 2026, agentic AI deployments are multiplying token consumption 20-30x compared to standard generative AI. Agent runtimes are becoming a new operating system layer. Industry projections suggest 50-100 billion AI agents operating by the end of the year, scaling to trillions within a decade. The infrastructure for these agents is, today, almost entirely centralized — running on hyperscaler GPUs, controlled by platform providers, subject to rate limits and acceptable use policies that constrain what agents can do.

Mjolnir offers an alternative model. Its agent SDK — an HTTP API running on localhost:5001 inside every VM — gives agents running in a Mjolnir VM the ability to:

- **Spawn sub-agents** (`POST /spawn`): An agent can create new VMs, each with its own isolated environment, and delegate work to them. The parent-child relationship is tracked through the orchestrator.

- **Checkpoint their work** (`POST /snapshot`): An agent can snapshot its VM at any point, creating a named, restorable save point. This enables long-running tasks to be interrupted and resumed, and enables speculative branching — try an approach, snapshot, try another, and return to whichever succeeded.

- **Communicate with peers** (`POST /send`, `GET /recv`): Agents can send structured messages to other VMs by ID and receive messages with long-polling. The dormant registry ensures that messages sent to a sleeping agent trigger its restoration — computation resumes on demand.

- **Signal completion** (`POST /done`): An agent can signal that it has finished its current work. Mjolnir snapshots the VM and puts it to sleep, freeing resources while preserving state. When a new message arrives, the VM is automatically restored from its snapshot and the message is delivered.

This is not container orchestration. It is not function-as-a-service. It is a model where agents are first-class participants in a computational fabric — able to spawn, communicate, checkpoint, sleep, wake, and migrate. Each agent runs in full hardware-isolated VM (not a container, not a namespace — a real virtual machine with its own kernel), providing security isolation that matches the autonomy being granted.

The dormant/restore lifecycle is particularly significant. It means that agent populations can scale beyond the memory of any single host. Thousands of agents can exist in a Mjolnir cluster, most of them dormant snapshots consuming only disk space, awakened on demand when work arrives. This is computation as a *coroutine* at the infrastructure level — yield when idle, resume when needed.

---

## Why Elixir and the BEAM

The choice of Elixir and OTP for Mjolnir's orchestration layer is not incidental. It is architectural.

The BEAM virtual machine — Erlang's runtime, on which Elixir compiles — was built for telephony switches that needed to handle millions of concurrent connections with five-nines uptime. Its design principles map directly to the requirements of VM orchestration:

**Lightweight processes and supervision.** Each Mjolnir VM is managed by a GenServer — an OTP process that weighs approximately 2KB of memory. These processes are organized into supervision trees: if a VM process crashes, its supervisor restarts it according to a defined strategy. The "let it crash" philosophy means that error handling is structural rather than defensive — instead of wrapping every operation in try/catch, you define recovery policies at the supervision level and let individual processes fail cleanly.

**Message passing and isolation.** BEAM processes do not share memory. They communicate through asynchronous message passing — the same model used for inter-VM communication in Mjolnir. This means the orchestrator itself is resistant to the cascading failures that plague shared-state systems. A misbehaving VM process cannot corrupt the state of another.

**Distribution as a first-class primitive.** BEAM nodes can form clusters where processes on different physical machines communicate transparently. The same `GenServer.call` that reaches a local VM process can reach one on a remote node. This makes the multi-node Mjolnir cluster a natural extension of the single-node architecture, not a rewrite.

**Hot code reloading.** OTP supports upgrading running code without restarting the system. For an orchestrator managing long-lived VMs, this means deploying fixes and features without disrupting running workloads — a property that matters more as the VM fleet grows.

The Registry, DynamicSupervisor, and TaskSupervisor that form Mjolnir's supervision tree are not just implementation details. They are the reason Mjolnir can treat VMs as managed processes — spawning them dynamically, monitoring their health, cleaning up their resources on termination, and recovering from failures automatically. OTP provides, out of the box, the primitives that other orchestration systems spend years rebuilding.

---

## The Road Ahead

Mjolnir is early. The single-node orchestrator works. VMs boot in seconds. Snapshots are instant. The guest agent handles command execution, shell access, inter-VM messaging, and the agent SDK. Iroh provides NAT-traversing connectivity. The dormant/restore lifecycle enables agent coroutines.

What remains is the distributed fabric:

**Multi-node clustering.** BEAM distribution with libcluster for automatic node discovery, :pg for process groups, and Syn for global process registration. This turns isolated Mjolnir nodes into a unified compute surface.

**Cross-node snapshot replication.** BTRFS send/receive, combined with Iroh's content-addressed blob transfer, enables snapshots to be replicated between nodes. A VM can be checkpointed on one node and restored on another. Combined with BLAKE3 content addressing, snapshots become verifiable — the hash of the snapshot data proves its integrity without trusting the node that sent it.

**Decentralized VM migration.** Live migration via Cloud Hypervisor, or cold migration via snapshot transfer. A VM's cryptographic identity (its Iroh keypair) can optionally travel with it, maintaining its network address across physical moves.

**Mesh networking.** Nodes discover each other through Iroh's relay infrastructure or direct peer-to-peer connections. No central registry. No DNS dependency. Just cryptographic identities and the protocols to find them.

**Capability-based access control.** Rather than ACLs managed by a central authority, access to VMs and resources is mediated by cryptographic capabilities — unforgeable tokens that grant specific permissions and can be delegated without contacting an issuer.

Each of these extensions builds on the foundation already in place. The supervision tree scales. The message-passing model distributes. The snapshot primitives compose. The cryptographic identities federate.

---

## The World We Are Building Toward

Imagine a network of Mjolnir nodes — some on dedicated servers in data centers, some on recycled laptops in community spaces, some on edge devices in remote locations. Each node is sovereign: owned and operated by its administrator, running its own workloads, applying its own policies. But each node is also a peer in a larger fabric, able to accept migrated VMs, replicate snapshots, and route agent messages.

An AI agent running on this network can spawn sub-agents across multiple nodes, checkpoint its work at meaningful intervals, go dormant when waiting for external input, and resume when the input arrives — potentially on a different continent. Its identity is cryptographic, its state is content-addressed, its communication is peer-to-peer. No platform provider can revoke its access. No terms-of-service change can render its work inaccessible. No single point of failure can bring it down.

This is not the cloud as we know it. It is not "decentralized cloud" as marketing speak. It is something older and more fundamental — a return to the internet's original architecture of autonomous, cooperating peers, rebuilt with modern primitives: hardware-isolated VMs instead of bare processes, cryptographic identity instead of passwords, content-addressed storage instead of file paths, peer-to-peer networking instead of client-server.

Brewster Kahle asked us to lock the web open. The decentralized web community built the storage and networking layers to do it. Mjolnir is building the compute layer.

The hammer falls where you choose to swing it.
