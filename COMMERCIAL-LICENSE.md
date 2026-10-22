# Mjolnir — Commercial License

Mjolnir's **host** (Elixir orchestrator, guest agent, gateway, blob door)
is **dual-licensed**. You may use that host under **either**:

1. The **GNU Affero General Public License v3.0 or later** (AGPL-3.0-or-later),
   the license in [`LICENSE`](LICENSE) — free of charge, forever; or
2. A **commercial license** from World Tree Network Foundation, described
   below.

The **consumer CLI** (`mj` / `mjolnir`) and its libraries
(`mjolnir-api`, `mjolnir-protocol`) are **MIT**. You do not need a
commercial license for those crates. See [`NOTICE`](NOTICE).

You only need a commercial license if the AGPL's obligations don't work for
your product. If you're happy to comply with the AGPL, you owe nothing and
can stop reading. Selling hardware that runs unmodified Mjolnir, with this
repository as the source offer, does **not** require a commercial license.

---

## When you need a commercial license

The AGPL is a strong copyleft license. Under it, **section 5** requires that
anyone you convey a modified version to receives the complete corresponding
source under the AGPL, and **section 13** extends that to *network use*: if
you let users interact with a modified Mjolnir host over a network, you must
offer them its complete corresponding source.

You will likely want a **commercial license** if any of the following apply
and you do **not** wish to release your corresponding source under the AGPL:

- You embed the Mjolnir host in a **proprietary appliance** or firmware
  image that you sell or lease.
- You offer a **hosted / SaaS** control plane built on the Mjolnir host
  and cannot or will not disclose its source under AGPL §13.
- You **link or combine** AGPL host code with proprietary software in a
  way that would make that software a derivative work subject to the AGPL.
- Your legal/procurement policy **prohibits AGPL** software in shipped
  products.

A commercial license grants you the same host code under terms that
**remove the AGPL's copyleft and network-source-disclosure obligations**.

## How to inquire

Terms are negotiated per deal. Contact **duke@worldtree.io**.

The CLA in [`CLA.md`](CLA.md) is what makes this dual-license possible.
Contributions are accepted only from signers of that CLA.
