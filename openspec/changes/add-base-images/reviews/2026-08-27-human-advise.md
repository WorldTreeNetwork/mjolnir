# add-base-images — human advise

> **ADVISE:** accept-with-nits

**Reader:** Duke (human), 2026-08-27, in chat.
**Author:** Grok 4.6 (same family; this file records the human
accept, it is not a Grok self-accept).

## Verdict

Accept D1–D4 as written. Nit: declared live images that predate
the current recipe are not the catalog — rebuild them
(`ubuntu-24.04` first). Recorded as Decision 5.

## Steelman against

Rebuilding `@base/ubuntu-24.04` while 26 VMs run looks scary. Those
VMs own `@vms/<uuid>` clones; replacing the template does not
teardown them. New spawns (and `mj deploy` after retire) need a
current agent baked in because inject is a silent no-op
(`mjolnir-hjnz`). Leaving Jun 23 ubuntu in place would make D3 a
paper contract.

## Tradeoff

A failed debootstrap deletes the live `@base/` name. Mitigated by
`@snapshots/<name>-pre-rebuild-<date>` before replace. Cost is
debootstrap time (ubuntu minutes; CI longer because rust/zig via
mise), not VM downtime.

## Findings

None on D1–D4. D5 is the only amend.

## Implementer gaps

- Snapshot before delete.
- Current `AGENT_BIN` (host path existed 2026-08-27 21:20 after a
  same-day copy; still rebuild from the recipe so the image is
  reproducible).
- Probe spawn after ubuntu; then CI, buzz-agent, arch.
- Do not rebuild `deploy-node-bun` or `tatastu-agent`.
