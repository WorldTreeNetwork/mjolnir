# Advise — add-lan-file-server (architecture, fable, re-read 2 after owner-root amend)

> **ADVISE:** accept
> **READER:** fable-5.1-arch-review
> **SPAWN:** .spawns/advise-add-lan-file-server-reread2-1788538602-481641-a3213196

Change: `add-lan-file-server` (bead `mjolnir-h2fp.2`, ACTIVE BUILD).
Rigor: architecture. Density: lean. Author family: Grok. Re-read of
the amend that closed the one owed box from
`reviews/2026-09-04-reread-advise.md` (cap root of trust). All three
prior reviews stand untouched. Do not fold. Do not `act`. No
product code.

---

## Blind take (written before design.md / tasks.md)

1. Pin: `ownership(h)` is set once, at first put, and never rewritten. A second put of identical bytes must not re-own `h`; the spec must say what the second putter gets (accept-no-op or refuse) and that they cannot read `h` without the owner's cap.
2. Pin: "root issuer equals owner" is necessary but not sufficient. Every link in a delegation chain must verify (issuer of link N+1 is `granted_to` of link N, all signatures good). That check must be the library's, never reimplemented in the guest.
3. Pin: `ownership(h)` must be as durable as the bytes. If it lives only in guest RAM or an ephemeral rootfs, a VM rebuild resets ownership and the first putter after the reset re-owns every existing hash. It has to sit beside the blob, on a durable subvolume or in blob-door metadata.
4. Pin: the owner reads via a self-issued cap where root issuer = granted_to = ownership(h). One verification path, no owner bypass branch.
5. Refuse: the share holding an issuing key. If the guest issues caps, root issuer is the guest key, never the putter, and the owner-root check either fails on every read or is silently satisfied by making the guest the owner. The spec line "SHALL issue Caps in that namespace" reads as the guest issuing. Caps must be issued client-side by the owner's storage-auth key; the guest only verifies.
6. Refuse: ownership transfer, co-owners, or delete semantics in this change. Owner-only delete can come later.
7. Pin: put is open to any verified identikey identity, so ownership is first-come. That allows hash squatting on predictable content and unbounded disk fill from any LAN identity. Acceptable for a LAN share if said out loud; a quota is a follow-up.
8. Pin: ownership fingerprint and `granted_to` share the storage-auth namespace `Blake3(raw 32-byte Ed25519)`. Never the §5 dcbor fingerprint. Same rule as the prior reread.
9. Tradeoff: owner-root closes the self-issued-cap hole, at the cost that sharing requires the owner's key to sign a cap out of band. No server-mediated grants. Right call for a LAN share; wrong call would be adding an "issue on my behalf" endpoint.
10. One test I want named: put `h` as A, self-issue cap as B for `h`, GET as B → refused; A issues cap to B → GET as B → bytes. Plus the durability test: restart the guest, GET as A still works, B's self-cap still refused.

---

## Compare (after design.md / tasks.md / prior reviews)

The owed box is closed, and closed the way the prior reread asked.

- **Design, "Fingerprint join", last paragraph.** Put is
  identikey-auth gated; first put records `ownership(h) = g_putter`
  via `OwnershipStore::register`, first putter wins, a different
  owner is refused; GET requires the cap or chain-root issuer to
  equal `ownership(h)`; issuer keys learned from `Verified` at auth
  time keyed by `g`; self-issued cap on someone else's hash does not
  read. That is items (1), (2), (4), (5), (8), (9) of the blind take
  answered in one paragraph.
- **Spec, "Data access is recrypt-storage-auth".** Gains the two
  SHALLs (first put records ownership; GET requires root issuer =
  owner). "Cap permits read" now carries `ownership(h) = g` and
  "whose root issuer is `g`". New scenario "Cap issued by non-owner"
  is the negative half of blind item (10) and is testable as
  written.
- **Verified against the crate.** `memory/ownership.rs:38-52` and
  `sqlite/ownership.rs:48-79`: same-owner re-register is idempotent,
  different owner is `AlreadyExists`. So "a different owner is
  refused" in design is the crate's behaviour, not new logic, and
  blind item (1) is answered as *refuse*.
- **Blind item (5), share-held issuing key.** Spec and design both
  say the share "issues Caps in that namespace". Checked stock
  `recrypt-server/src/routes/keyspaces.rs:17-19`: the server holds
  no issuing key; grants are client-signed and `issuer` MUST equal
  the authenticated caller. Read that way, "issues" means the share
  accepts and stores caps signed by the caller, and owner-root then
  holds by construction. If an implementer instead gave the guest a
  signing key, every GET would fail loudly (guest key is never
  `ownership(h)`), so the wrong reading cannot silently reopen the
  hole. Nit, not a box.
- **Blind item (3), ownership durability.** Design delta (4)
  "durable caps/index" covers the ownership table implicitly; the
  prior reread's implementer note says so explicitly. A cold guest
  with an empty table refuses every GET, which is the safe failure.
  Nit.
- **Blind item (7), open put / hash squatting / disk fill.** Not in
  design. Both are bounded by "anyone on the LAN with an IdentiKey",
  which is the trust boundary this share already chose. Follow-up,
  not this change.

Steelman for the author: the reread asked for one paragraph and one
scenario. Both landed, the wording matches the crate's actual
semantics, and nothing from the four earlier boxes was disturbed.
The remaining items are wording and implementer notes.

---

## Nits (not boxes; fold into `h2fp.3` brief or a one-line design edit)

1. **"Issues Caps" → "accepts caps signed by the caller."** One
   clause in design "Fingerprint join" and spec "Data access":
   the share holds no issuing key; a stored cap's `issuer` must
   equal the authenticated `g`, as stock keyspaces routes already
   require. Removes the only reading under which owner-root cannot
   be satisfied.
2. **Name the ownership table in delta (4).** "durable caps, index,
   and ownership" so the anchor is not lost on guest rebuild.
3. **Re-put by a non-owner returns a distinct error.** Design says
   refused; say it surfaces as conflict, not as "already exists,
   you now own it". The putter must not infer they can read `h`.
4. **Chain verification stays the crate's.** `verify_chain` walks
   `parent.granted_to == child.issuer` and signatures; the guest
   adds only the root-issuer == owner comparison on top. Do not
   reimplement the walk.
5. **Two tests to name in `h2fp.3`.** (a) A puts `h`; B self-issues
   for `h` → refused; A issues to B → bytes. (b) Restart the guest;
   A still reads, B's self-cap still refused.

Prior-reread implementer notes (signature policy, Ed25519 alg guard,
byte-transparent v6 proxy, door dedup vs ownership) still apply and
are not repeated.

---

## Verdict

Accept. The cap gate now has a root of trust: the owner recorded at
the first identikey-auth-gated put, compared against the chain-root
issuer on GET, with issuer keys learned at auth time. Self-issued
caps do not read. The four earlier boxes remain closed. Proceed to
`act` on `h2fp.3` with the nits above carried into its brief.
