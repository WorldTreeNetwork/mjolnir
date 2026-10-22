# Transfer: Mjolnir → World Tree Network Foundation

Moving this project out of **Identikey Inc.** and into the **World Tree
Network Foundation** (WTNF). Intended home:
**`github.com/WorldTreeNetwork/mjolnir`**. Licensing contact:
**duke@worldtree.io**.

Until the GitHub transfer completes, the working clone URL remains
`github.com/Identikey/mjolnir` (this remote still resolves). Do not
publish a WorldTreeNetwork clone URL that 404s.

License split (AGPL host, MIT CLI) is documented in
[NOTICE](../../NOTICE) and
[docs/philosophy/licensing-and-components.md](../philosophy/licensing-and-components.md).
Playbook borrowed from
[lightning-mesh's transfer](https://github.com/WorldTreeNetwork/lightning-mesh/blob/main/docs/transfer/lightning-mesh-to-wtnf.md).

---

## 1. In-repo license / ownership sweep

- [x] Root `LICENSE` (AGPL-3.0-or-later)
- [x] `NOTICE` (Foundation copyright; MIT exception for client crates)
- [x] MIT `LICENSE` in `native/mjolnir_client`, `mjolnir_api`, `mjolnir_protocol`
- [x] `CONTRIBUTING.md` inbound = outbound
- [x] SPDX on crate manifests and crate roots
- [x] README / hardware / mini-hoster docs
- [ ] GitHub repo transfer Identikey → WorldTreeNetwork (repo does not
      exist under WorldTreeNetwork yet)
- [ ] `git remote set-url origin git@github.com:WorldTreeNetwork/mjolnir.git`
- [x] CLA + commercial-exception stub (`CLA.md`, `COMMERCIAL-LICENSE.md`).
      Hardware sales of unmodified AGPL still do not require buying the
      exception. Wire CLA Assistant after the GitHub org transfer.

IdentiKey as a *product* name (Sites, identity) stays.

## 2. GitHub repository transfer

Same sequence as Lightning Mesh:

1. Merge this sweep to `main` on `Identikey/mjolnir` **before**
   transferring, so the new org's default view is already correct.
2. Transfer: Settings → Danger Zone → Transfer ownership →
   `WorldTreeNetwork`, repo name `mjolnir`.
3. Update local remotes. GitHub redirects the old URL.
4. Re-create Actions secrets, branch protections, and the Forgejo
   mirror env (`/etc/mjolnir/github-forgejo-mirror.env`) — those do
   not travel.

## 3. Identity

- [ ] `duke@worldtree.io` is live (licensing + security)
- [ ] Confirm `worldtree.network` / `worldtree.io` are Foundation-held
